import Foundation

// tx3g samples are a big-endian length, then UTF-8 or UTF-16 text, then
// optional atoms. The read loop follows the same AVAssetReader approach as
// Convolution's LocalSubtitleSource (MIT, https://github.com/illixion/Convolution):
// nil output settings, so the stored samples come back unchanged, and empty
// samples are the gaps between cues. This file is a separate implementation.
//
// Non-tx3g tracks are classified and returned; they are not read.
// ffmpeg is intentionally not wired in. SubtitleMediaReading is the seam.

#if canImport(AVFoundation)
import AVFoundation
import CoreMedia

public struct AVFoundationSubtitleReader: SubtitleMediaReading {
    public init() {}

    public func inspect(file: URL) async throws -> MediaInspection {
        try await AVFoundationSession().inspect(file: file)
    }

    public func cues(
        file: URL,
        trackID: Int,
        onSampleTime: @escaping @Sendable (Int) -> Void
    ) -> AsyncThrowingStream<SubtitleCue, Error> {
        let session = AVFoundationSession()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let cues = try await session.collectCues(
                        file: file,
                        trackID: trackID,
                        onSampleTime: onSampleTime
                    )
                    for cue in cues {
                        continuation.yield(cue)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                session.cancel()
                task.cancel()
            }
        }
    }
}

/// Holds the AVFoundation objects. Those types are not promised Sendable across
/// every SDK this app builds with, and the reader is used from one task at a time.
private final class AVFoundationSession: @unchecked Sendable {
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let reader = self.reader
        lock.unlock()
        reader?.cancelReading()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func store(_ reader: AVAssetReader) {
        lock.lock()
        self.reader = reader
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled {
            reader.cancelReading()
        }
    }

    func inspect(file: URL) async throws -> MediaInspection {
        if isCancelled { throw CancellationError() }
        let asset = AVURLAsset(url: file, options: Self.assetOptions)
        if try await asset.load(.hasProtectedContent) {
            throw SubtitleExtractionError.protectedContent
        }
        let duration = try await asset.load(.duration)
        let durationMs = MediaTime.milliseconds(value: duration.value, timescale: duration.timescale)

        var discovered: [DiscoveredMediaTrack] = []
        let kinds: [(AVMediaType, SubtitleMediaKind)] = [
            (.text, .text),
            (.subtitle, .subtitle),
            (.closedCaption, .closedCaption)
        ]
        for (mediaType, kind) in kinds {
            if isCancelled { throw CancellationError() }
            let tracks = try await asset.loadTracks(withMediaType: mediaType)
            for track in tracks {
                let formats = try await track.load(.formatDescriptions)
                let language = try await track.load(.languageCode)
                let tag = try await track.load(.extendedLanguageTag)
                let header = Self.header(of: formats)
                discovered.append(DiscoveredMediaTrack(
                    trackID: Int(track.trackID),
                    mediaKind: kind,
                    codec: Self.codec(of: formats),
                    languageCode: language,
                    extendedLanguageTag: tag,
                    title: await Self.title(of: track),
                    displayFlags: header?.displayFlags
                ))
            }
        }
        return MediaInspection(
            tracks: TrackClassifier.classifyAll(discovered),
            durationMilliseconds: durationMs
        )
    }

    func collectCues(
        file: URL,
        trackID: Int,
        onSampleTime: @Sendable (Int) -> Void
    ) async throws -> [SubtitleCue] {
        if isCancelled || Task.isCancelled { throw CancellationError() }
        let asset = AVURLAsset(url: file, options: Self.assetOptions)
        if try await asset.load(.hasProtectedContent) {
            throw SubtitleExtractionError.protectedContent
        }
        guard let track = try await asset.loadTrack(withTrackID: CMPersistentTrackID(trackID)) else {
            throw SubtitleExtractionError.unreadable("That subtitle track is not in the file.")
        }
        let formats = try await track.load(.formatDescriptions)
        let face = Self.header(of: formats)?.defaultFaceStyle ?? 0

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw SubtitleExtractionError.unreadable("Could not read the subtitle track.")
        }
        reader.add(output)
        store(reader)
        guard reader.startReading() else {
            throw SubtitleExtractionError.unreadable(Self.message(from: reader.error))
        }

        var samples: [TX3GTimedSample] = []
        while !isCancelled && !Task.isCancelled {
            try Task.checkCancellation()
            guard let sample = output.copyNextSampleBuffer() else { break }
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            let timed = try Self.timedSample(from: sample, defaultFaceStyle: face)
            onSampleTime(timed.startMilliseconds)
            samples.append(timed)
        }
        if isCancelled || Task.isCancelled || reader.status == .cancelled {
            reader.cancelReading()
            throw CancellationError()
        }
        if reader.status == .failed {
            throw SubtitleExtractionError.unreadable(Self.message(from: reader.error))
        }
        return CueStreamAssembler.cues(from: samples)
    }

    /// Precise duration makes AVFoundation walk the whole movie. Subtitle tracks
    /// don't need that, and a 50 GB rip on a network share shouldn't be scanned
    /// just to list its text tracks.
    private static let assetOptions: [String: Any] = [
        AVURLAssetPreferPreciseDurationAndTimingKey: false
    ]

    private static func title(of track: AVAssetTrack) async -> String? {
        do {
            let items = try await track.load(.commonMetadata)
            for item in items where item.commonKey == .commonKeyTitle {
                if let value = try await item.load(.stringValue) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func codec(of formats: [CMFormatDescription]) -> String {
        let codes = formats.map { FourCC.string(CMFormatDescriptionGetMediaSubType($0)) }
        if let text = codes.first(where: { $0 == "tx3g" }) { return text }
        return codes.first ?? "unknown"
    }

    private static func header(of formats: [CMFormatDescription]) -> TX3GSampleEntry.Header? {
        for description in formats {
            guard let extensions = CMFormatDescriptionGetExtensions(description) else { continue }
            guard let data = TX3GSampleEntry.findSampleEntry(in: extensions as Any) else { continue }
            if let header = TX3GSampleEntry.header(in: data) { return header }
        }
        return nil
    }

    private static func timedSample(from sample: CMSampleBuffer, defaultFaceStyle: UInt8) throws -> TX3GTimedSample {
        let startTime = CMSampleBufferGetPresentationTimeStamp(sample)
        let duration = CMSampleBufferGetDuration(sample)
        let start = MediaTime.milliseconds(value: startTime.value, timescale: startTime.timescale)
        let end: Int?
        if duration.isValid, duration.value > 0, startTime.isValid {
            let endTime = CMTimeAdd(startTime, duration)
            let endMs = MediaTime.milliseconds(value: endTime.value, timescale: endTime.timescale)
            end = endMs > start ? endMs : nil
        } else {
            end = nil
        }
        guard let buffer = sample.dataBuffer else {
            return TX3GTimedSample(startMilliseconds: start, endMilliseconds: end, text: nil, isForced: false)
        }
        let data = try bytes(from: buffer)
        switch TX3GSample.parse(data, defaultFaceStyle: defaultFaceStyle) {
        case .gap:
            return TX3GTimedSample(startMilliseconds: start, endMilliseconds: end, text: nil, isForced: false)
        case .malformed:
            throw SubtitleExtractionError.malformedSample
        case let .cue(text, isForced):
            return TX3GTimedSample(startMilliseconds: start, endMilliseconds: end, text: text, isForced: isForced)
        }
    }

    /// Copy the bytes out before the next sample. `alwaysCopiesSampleData` is
    /// false, so the buffer can be reused.
    private static func bytes(from buffer: CMBlockBuffer) throws -> Data {
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            buffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &pointer
        )
        guard status == kCMBlockBufferNoErr, let pointer, length > 0 else {
            if status == kCMBlockBufferNoErr, length == 0 { return Data() }
            throw SubtitleExtractionError.malformedSample
        }
        return Data(bytes: pointer, count: length)
    }

    private static func message(from error: Error?) -> String {
        let text = error?.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text, !text.isEmpty { return text }
        return "Could not read the subtitle track."
    }
}

private enum FourCC {
    static func string(_ code: FourCharCode) -> String {
        let value = UInt32(code)
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        guard let text = String(bytes: bytes, encoding: .ascii) else {
            return String(format: "%08x", value)
        }
        let printable = text.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " }
        if printable {
            let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
            return trimmed.isEmpty ? "unknown" : trimmed
        }
        return String(format: "%08x", value)
    }
}
#endif
