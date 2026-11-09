import Foundation

// Tries `AVAssetReaderOutputCaptionAdaptor` on a discrete `c608` track and logs
// the comparison against the cleaned ffmpeg SRT. WWDC21 scoped this adaptor to
// `.itt` and `.scc`. Apple does not document it for MP4 `c608`, whose nil-settings
// samples are QTFF `cdat` byte pairs. This file does not decode those bytes.
// `outputCaptionProvider` is macOS 26 and is not used.
//
// The result is a log line. `ClosedCaptionSpike.writer` decides what is written,
// and that is still ffmpeg.

#if canImport(AVFoundation)
import AVFoundation
import CaptionExceptionBox
import CoreMedia

enum NativeClosedCaptionReader {
    /// Logs the adaptor read. Throws `CancellationError` only. A failed or empty
    /// adaptor read is logged and does not fail the ffmpeg extract.
    static func logComparison(file: URL, trackID: Int, reference: [SubtitleCue]) async throws {
        let session = NativeCaptionSession()
        let comparison = try await withTaskCancellationHandler {
            try await session.readAndCompare(file: file, trackID: trackID, reference: reference)
        } onCancel: {
            session.cancel()
        }
        let warning = comparison.failure != nil || !comparison.matchesCleanedReference
        for line in ClosedCaptionSpike.logLines(comparison) {
            let isPreview = line.contains(" roll-up ")
            DebugLog.shared.record(.work, line, isWarning: warning && !isPreview)
        }
    }
}

/// Holds the reader so cancel can stop `nextCaptionGroup`. AVFoundation types
/// are not promised Sendable. One extract uses one session.
private final class NativeCaptionSession: @unchecked Sendable {
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

    func readAndCompare(
        file: URL,
        trackID: Int,
        reference: [SubtitleCue]
    ) async throws -> ClosedCaptionComparison {
        if isCancelled || Task.isCancelled { throw CancellationError() }
        do {
            return try await read(file: file, trackID: trackID, reference: reference)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = text.isEmpty ? "Could not read the closed-caption track." : text
            return ClosedCaptionSpike.failed(trackID: trackID, reason: reason, reference: reference)
        }
    }

    private func read(
        file: URL,
        trackID: Int,
        reference: [SubtitleCue]
    ) async throws -> ClosedCaptionComparison {
        if isCancelled || Task.isCancelled { throw CancellationError() }
        let asset = AVURLAsset(url: file, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        if try await asset.load(.hasProtectedContent) {
            return ClosedCaptionSpike.failed(
                trackID: trackID,
                reason: "This file is DRM-protected.",
                reference: reference
            )
        }
        try Task.checkCancellation()
        guard let track = try await asset.loadTrack(withTrackID: CMPersistentTrackID(trackID)) else {
            return ClosedCaptionSpike.failed(
                trackID: trackID,
                reason: "The closed-caption track is not in the file.",
                reference: reference
            )
        }
        try Task.checkCancellation()

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            return ClosedCaptionSpike.failed(
                trackID: trackID,
                reason: "Could not read the closed-caption track.",
                reference: reference
            )
        }
        reader.add(output)
        store(reader)

        let sink = CaptionValidationSink()
        var adaptorBox: AVAssetReaderOutputCaptionAdaptor?
        if let reason = MP4SubRipCatch({
            adaptorBox = AVAssetReaderOutputCaptionAdaptor(assetReaderTrackOutput: output)
        }) {
            reader.cancelReading()
            return ClosedCaptionSpike.failed(trackID: trackID, reason: reason, reference: reference)
        }
        guard let adaptor = adaptorBox else {
            reader.cancelReading()
            return ClosedCaptionSpike.failed(
                trackID: trackID,
                reason: "The caption adaptor did not start.",
                reference: reference
            )
        }
        adaptor.validationDelegate = sink

        guard reader.startReading() else {
            return ClosedCaptionSpike.failed(
                trackID: trackID,
                reason: Self.message(from: reader.error),
                reference: reference
            )
        }

        var groupCount = 0
        var cues: [CaptionCueSnapshot] = []
        while !isCancelled && !Task.isCancelled {
            try Task.checkCancellation()
            var next: AVCaptionGroup?
            if let reason = MP4SubRipCatch({
                next = adaptor.nextCaptionGroup()
            }) {
                reader.cancelReading()
                return ClosedCaptionSpike.failed(
                    trackID: trackID,
                    reason: reason,
                    nativeGroupCount: groupCount,
                    nativeCues: cues,
                    reference: reference,
                    validationSkips: sink.skips
                )
            }
            guard let next else { break }
            groupCount += 1
            if let cue = try Self.snapshot(from: next) {
                cues.append(cue)
            }
        }
        if isCancelled || Task.isCancelled || reader.status == .cancelled {
            reader.cancelReading()
            throw CancellationError()
        }
        let comparison = ClosedCaptionSpike.compare(
            trackID: trackID,
            nativeGroupCount: groupCount,
            nativeCues: cues,
            reference: reference,
            validationSkips: sink.skips
        )
        if reader.status == .failed {
            return ClosedCaptionSpike.failed(
                trackID: trackID,
                reason: Self.message(from: reader.error),
                nativeGroupCount: groupCount,
                nativeCues: cues,
                reference: reference,
                validationSkips: sink.skips
            )
        }
        if groupCount == 0 {
            return ClosedCaptionSpike.failed(
                trackID: trackID,
                reason: "The caption adaptor vended no caption groups.",
                nativeGroupCount: 0,
                nativeCues: [],
                reference: reference,
                validationSkips: sink.skips
            )
        }
        return comparison
    }

    private static func snapshot(from group: AVCaptionGroup) throws -> CaptionCueSnapshot? {
        var lines: [String] = []
        var rollUp = false
        for caption in group.captions {
            try Task.checkCancellation()
            if caption.region?.scroll == .rollUp {
                rollUp = true
            }
            let text = SRTDocument.normalize(styledText(caption))
            if !text.isEmpty {
                lines.append(text)
            }
        }
        guard !lines.isEmpty else { return nil }
        let (start, end) = cueTimes(group.timeRange)
        return CaptionCueSnapshot(
            startMilliseconds: start,
            endMilliseconds: end,
            text: lines.joined(separator: "\n"),
            isRollUp: rollUp
        )
    }

    /// Italic runs become `<i>`, which is what the cleaned ffmpeg SRT keeps.
    /// The index is a UTF-16 offset, matching `fontStyle(at:range:)`.
    private static func styledText(_ caption: AVCaption) -> String {
        let raw = caption.text as NSString
        guard raw.length > 0 else { return "" }
        var result = ""
        var location = 0
        var italicOpen = false
        var steps = 0
        while location < raw.length && steps < raw.length + 2 {
            steps += 1
            var range = NSRange(location: NSNotFound, length: 0)
            let style = caption.fontStyle(at: location, range: &range)
            let end: Int
            if range.location != NSNotFound, range.length > 0, range.location <= location {
                end = min(raw.length, range.location + range.length)
            } else {
                end = min(raw.length, location + 1)
            }
            if end <= location { break }
            let italic = style == .italic
            if italic != italicOpen {
                result += italic ? "<i>" : "</i>"
                italicOpen = italic
            }
            result += raw.substring(with: NSRange(location: location, length: end - location))
            location = end
        }
        if italicOpen {
            result += "</i>"
        }
        return result
    }

    private static func cueTimes(_ range: CMTimeRange) -> (Int, Int) {
        let start = milliseconds(range.start) ?? 0
        let end = milliseconds(range.end) ?? start
        return (start, end > start ? end : start + 1)
    }

    private static func milliseconds(_ time: CMTime) -> Int? {
        guard time.isValid, !time.isIndefinite, !time.isPositiveInfinity, !time.isNegativeInfinity else {
            return nil
        }
        guard time.timescale > 0 else { return nil }
        if time.value <= 0 { return 0 }
        return MediaTime.milliseconds(value: time.value, timescale: time.timescale)
    }

    private static func message(from error: Error?) -> String {
        let text = error?.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text, !text.isEmpty { return text }
        return "Could not read the closed-caption track."
    }
}

/// `validationDelegate` is weak, so the session keeps this for the read.
/// The callback is `AVAssetReaderCaptionValidationHandling` (the issue's
/// `AVCaptionValidationHandling` skips).
private final class CaptionValidationSink: NSObject, AVAssetReaderCaptionValidationHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func captionAdaptor(
        _: AVAssetReaderOutputCaptionAdaptor,
        didVendCaption _: AVCaption,
        skippingUnsupportedSourceSyntaxElements syntaxElements: [String]
    ) {
        lock.lock()
        stored.append(contentsOf: syntaxElements)
        lock.unlock()
    }

    var skips: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
#endif
