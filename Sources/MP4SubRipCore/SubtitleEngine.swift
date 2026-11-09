import Foundation

// The extraction engine. Probe lists tracks. Extract writes SRT.
// On macOS, `SubtitleEngine()` uses `RoutingSubtitleReader`: tx3g goes through
// AVFoundation, and a discrete EIA-608 (`c608`) track goes through ffmpeg.
// CEA-708, captions that live only in the video bitstream, bitmap, and WebVTT
// are reported and skipped.

/// Reads subtitle facts and samples out of one media file.
///
/// The app uses `SubtitleEngine()`, which picks the routing reader on macOS.
/// Tests pass their own reader. A `c608` track is read by the reader the engine
/// was given; the live reader sends that track to ffmpeg.
public protocol SubtitleMediaReading: Sendable {
    func inspect(file: URL) async throws -> MediaInspection
    /// Samples are visited in storage order. `onSampleTime` is the cue start
    /// in milliseconds, so a long read can report progress before the cues return.
    /// Call it from the reading task; it may hop elsewhere.
    func cues(
        file: URL,
        trackID: Int,
        onSampleTime: @escaping @Sendable (Int) -> Void
    ) -> AsyncThrowingStream<SubtitleCue, Error>
}

/// What to do when the SRT is already on disk. The queue asks once per batch;
/// the engine only applies the answer.
public enum OutputConflictPolicy: Equatable, Sendable {
    case skip
    case overwrite
    case keepBoth
}

public struct WrittenSubtitle: Equatable, Sendable {
    public var trackID: Int
    public var path: String
    public var cueCount: Int
    public var languageCode: String
    public var isForced: Bool

    public init(trackID: Int, path: String, cueCount: Int, languageCode: String, isForced: Bool) {
        self.trackID = trackID
        self.path = path
        self.cueCount = cueCount
        self.languageCode = languageCode
        self.isForced = isForced
    }
}

public struct SkippedSubtitle: Equatable, Sendable {
    public var trackID: Int
    public var reason: SubtitleSkipReason

    public init(trackID: Int, reason: SubtitleSkipReason) {
        self.trackID = trackID
        self.reason = reason
    }
}

public struct ExistingSubtitleOutput: Equatable, Sendable {
    public var trackID: Int
    public var path: String

    public init(trackID: Int, path: String) {
        self.trackID = trackID
        self.path = path
    }
}

public struct ExtractionOutcome: Equatable, Sendable {
    public var written: [WrittenSubtitle]
    public var skipped: [SkippedSubtitle]
    public var alreadyExists: [ExistingSubtitleOutput]

    public init(
        written: [WrittenSubtitle],
        skipped: [SkippedSubtitle],
        alreadyExists: [ExistingSubtitleOutput]
    ) {
        self.written = written
        self.skipped = skipped
        self.alreadyExists = alreadyExists
    }
}

/// Writes text subtitle tracks to SRT. Safe to use off the main thread.
public struct SubtitleEngine: Sendable {
    private let reader: any SubtitleMediaReading
    private let storage: ExtractionStorage

    /// AVFoundation for tx3g, ffmpeg for discrete `c608`, on macOS. On Linux,
    /// probe and extract throw `SubtitleExtractionError.unsupportedPlatform`
    /// so the pure pieces can still be tested.
    public init() {
        #if canImport(AVFoundation)
        self.init(reader: RoutingSubtitleReader(), storage: .live)
        #else
        self.init(reader: UnavailableSubtitleReader(), storage: .live)
        #endif
    }

    public init(reader: some SubtitleMediaReading) {
        self.init(reader: reader, storage: .live)
    }

    init(reader: some SubtitleMediaReading, storage: ExtractionStorage) {
        self.reader = reader
        self.storage = storage
    }

    /// Lists subtitle tracks. Does not read the cue samples.
    public func probe(file: URL) async throws -> [SubtitleTrack] {
        try Task.checkCancellation()
        try requireFile(file)
        do {
            let inspection = try await reader.inspect(file: file)
            DebugLog.shared.record(.work, "Probe \(file.lastPathComponent): \(Self.summary(inspection.tracks))")
            return inspection.tracks
        } catch {
            throw Self.mapped(error)
        }
    }

    /// Extracts `trackIDs`, or every extractable text track when `trackIDs` is nil.
    /// `outputDirectory` nil writes next to the movie.
    /// A cancel or a failure deletes any SRT this call created, including a half-written one.
    public func extract(
        file: URL,
        trackIDs: Set<Int>? = nil,
        outputDirectory: URL? = nil,
        alwaysIncludeLanguageCode: Bool = false,
        conflict: OutputConflictPolicy = .skip,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> ExtractionOutcome {
        try Task.checkCancellation()
        try requireFile(file)
        let directory = try outputFolder(outputDirectory, near: file)

        let inspection: MediaInspection
        do {
            inspection = try await reader.inspect(file: file)
        } catch {
            throw Self.mapped(error)
        }
        try Task.checkCancellation()
        DebugLog.shared.record(.work, "Probe \(file.lastPathComponent): \(Self.summary(inspection.tracks))")

        let selected = try Self.select(inspection.tracks, ids: trackIDs)
        var skipped = selected.compactMap { track -> SkippedSubtitle? in
            guard !track.isExtractable, let reason = track.skipReason else { return nil }
            return SkippedSubtitle(trackID: track.id, reason: reason)
        }
        for skip in skipped {
            DebugLog.shared.record(.work, "Skipped track \(skip.trackID): \(skip.reason.message)", isWarning: true)
        }

        let extractable = selected.filter(\.isExtractable)
        var collected: [(track: SubtitleTrack, cues: [SubtitleCue])] = []
        for (index, track) in extractable.enumerated() {
            try Task.checkCancellation()
            let cues: [SubtitleCue]
            do {
                cues = try await readCues(
                    file: file,
                    track: track,
                    duration: inspection.durationMilliseconds,
                    trackIndex: index,
                    trackCount: extractable.count,
                    progress: progress
                )
            } catch let error as SubtitleExtractionError {
                guard error == .needsFFmpeg else { throw error }
                let skip = SkippedSubtitle(trackID: track.id, reason: .needsFFmpeg)
                skipped.append(skip)
                DebugLog.shared.record(.work, "Skipped track \(skip.trackID): \(skip.reason.message)", isWarning: true)
                continue
            }
            var track = track
            if !cues.isEmpty, cues.allSatisfy(\.isForced) {
                track.isForced = true
            }
            if cues.contains(where: \.isForced) {
                track.hasForcedSamples = true
            }
            collected.append((track, cues))
            if inspection.durationMilliseconds > 0 {
                progress?((index + 1) * inspection.durationMilliseconds, inspection.durationMilliseconds * extractable.count)
            }
        }

        let fileNames = SubtitleFileNames.names(
            baseName: SubtitleFileNames.baseName(forFile: file.path),
            tracks: collected.map(\.track),
            alwaysIncludeLanguageCode: alwaysIncludeLanguageCode
        )

        // Partials stay beside the movie until every track has been written.
        // Only then are they moved onto the final names, so a failure while
        // reading or writing does not replace an SRT the user already had.
        // `replaceItemAt` is avoided: Linux Foundation reports "file doesn't
        // exist" for a file that is there.
        var partials: [URL] = []
        var committed: [URL] = []
        var finished = false
        defer {
            if !finished {
                for url in partials { storage.remove(url) }
                for url in committed { storage.remove(url) }
            }
        }

        struct PendingWrite {
            var track: SubtitleTrack
            var cueCount: Int
            var final: URL
            var partial: URL
        }
        var pending: [PendingWrite] = []
        var alreadyExists: [ExistingSubtitleOutput] = []
        for item in collected {
            try Task.checkCancellation()
            guard let name = fileNames[item.track.id] else { continue }
            let plan: OutputPlan
            do {
                plan = try planOutput(fileName: name, directory: directory, policy: conflict)
            } catch {
                throw Self.mapped(error)
            }
            switch plan {
            case let .skip(url):
                alreadyExists.append(ExistingSubtitleOutput(trackID: item.track.id, path: url.path))
                DebugLog.shared.record(.work, "Output exists \(url.lastPathComponent)", isWarning: true)
            case let .write(final):
                let partial = partialURL(for: final)
                let text = SRTDocument.render(item.cues)
                do {
                    try storage.write(Data(text.utf8), partial)
                } catch {
                    throw Self.mapped(error)
                }
                partials.append(partial)
                pending.append(PendingWrite(
                    track: item.track,
                    cueCount: item.cues.count,
                    final: final,
                    partial: partial
                ))
            }
        }

        var written: [WrittenSubtitle] = []
        for item in pending {
            try Task.checkCancellation()
            do {
                try storage.move(item.partial, item.final)
            } catch {
                throw Self.mapped(error)
            }
            partials.removeAll { $0 == item.partial }
            committed.append(item.final)
            written.append(WrittenSubtitle(
                trackID: item.track.id,
                path: item.final.path,
                cueCount: item.cueCount,
                languageCode: item.track.languageCode,
                isForced: item.track.isForced
            ))
            DebugLog.shared.record(.work, "Wrote \(item.final.lastPathComponent) (\(item.cueCount) cues)")
        }
        finished = true
        return ExtractionOutcome(written: written, skipped: skipped, alreadyExists: alreadyExists)
    }

    private func readCues(
        file: URL,
        track: SubtitleTrack,
        duration: Int,
        trackIndex: Int,
        trackCount: Int,
        progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [SubtitleCue] {
        let stream = reader.cues(file: file, trackID: track.id) { sampleTime in
            guard duration > 0, let progress else { return }
            let clamped = min(max(sampleTime, 0), duration)
            progress(trackIndex * duration + clamped, duration * trackCount)
        }
        var cues: [SubtitleCue] = []
        do {
            for try await cue in stream {
                try Task.checkCancellation()
                cues.append(cue)
                if duration <= 0 {
                    progress?(cues.count, 0)
                }
            }
        } catch {
            throw Self.mapped(error)
        }
        return cues
    }

    private func requireFile(_ file: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory)
        if !exists || isDirectory.boolValue {
            throw SubtitleExtractionError.fileNotFound
        }
    }

    private func outputFolder(_ override: URL?, near file: URL) throws -> URL {
        let directory = override ?? file.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SubtitleExtractionError.unreadable("The output folder can't be found.")
        }
        return directory
    }

    private enum OutputPlan {
        case skip(URL)
        case write(URL)
    }

    private func planOutput(fileName: String, directory: URL, policy: OutputConflictPolicy) throws -> OutputPlan {
        let final = directory.appendingPathComponent(fileName)
        switch policy {
        case .skip where storage.fileExists(final.path):
            return .skip(final)
        case .skip, .overwrite:
            return .write(final)
        case .keepBoth:
            var candidate = final
            var index = 1
            while storage.fileExists(candidate.path) {
                candidate = directory.appendingPathComponent(SubtitleFileNames.numbered(fileName, index: index))
                index += 1
                if index > 999 {
                    throw SubtitleExtractionError.unreadable("Could not find a free name for \(fileName).")
                }
            }
            return .write(candidate)
        }
    }

    private func partialURL(for final: URL) -> URL {
        let name = final.lastPathComponent + "." + UUID().uuidString + ".partial"
        return final.deletingLastPathComponent().appendingPathComponent(name)
    }

    private static func select(_ tracks: [SubtitleTrack], ids: Set<Int>?) throws -> [SubtitleTrack] {
        guard let ids else { return tracks }
        let known = Set(tracks.map(\.id))
        if let missing = ids.first(where: { !known.contains($0) }) {
            throw SubtitleExtractionError.unreadable("Subtitle track \(missing) is not in the file.")
        }
        return tracks.filter { ids.contains($0.id) }
    }

    private static func summary(_ tracks: [SubtitleTrack]) -> String {
        if tracks.isEmpty { return "no subtitle tracks" }
        return tracks.map { track in
            if track.isExtractable {
                let kind = track.codec == FFmpegClosedCaptions.codec ? "closed captions" : "text"
                var label = "\(kind) \(track.languageCode)"
                if track.isForced { label += " forced" }
                if track.isSDH { label += " sdh" }
                return label
            }
            return track.skipReason?.message ?? "not text"
        }.joined(separator: "; ")
    }

    private static func mapped(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if error is SubtitleExtractionError { return error }
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileWriteNoPermission, .fileWriteVolumeReadOnly, .fileWriteOutOfSpace:
                return SubtitleExtractionError.outputNotWritable
            case .fileReadNoSuchFile, .fileNoSuchFile:
                return SubtitleExtractionError.fileNotFound
            default:
                break
            }
        }
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return SubtitleExtractionError.unreadable("Could not read the file.") }
        return SubtitleExtractionError.unreadable(text)
    }
}

/// Where SRT bytes go. Tests substitute a disk that fails on command.
struct ExtractionStorage: Sendable {
    var fileExists: @Sendable (String) -> Bool
    /// Writes a complete SRT to a temporary name. `.atomic` so a crash does not
    /// leave a half-written file even at that temporary name.
    var write: @Sendable (Data, URL) throws -> Void
    /// Moves a finished temporary file onto its final name, replacing one that
    /// is already there.
    var move: @Sendable (_ partial: URL, _ final: URL) throws -> Void
    var remove: @Sendable (URL) -> Void

    static let live = ExtractionStorage(
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        write: { data, url in
            try data.write(to: url, options: .atomic)
        },
        move: { partial, final in
            let manager = FileManager.default
            if manager.fileExists(atPath: final.path) {
                try manager.removeItem(at: final)
            }
            try manager.moveItem(at: partial, to: final)
        },
        remove: { url in
            try? FileManager.default.removeItem(at: url)
        }
    )
}

struct UnavailableSubtitleReader: SubtitleMediaReading {
    func inspect(file: URL) async throws -> MediaInspection {
        throw SubtitleExtractionError.unsupportedPlatform
    }

    func cues(
        file: URL,
        trackID: Int,
        onSampleTime: @escaping @Sendable (Int) -> Void
    ) -> AsyncThrowingStream<SubtitleCue, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: SubtitleExtractionError.unsupportedPlatform)
        }
    }
}
