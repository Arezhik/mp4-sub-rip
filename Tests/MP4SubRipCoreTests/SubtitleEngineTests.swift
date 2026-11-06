import XCTest
@testable import MP4SubRipCore

final class SubtitleEngineTests: XCTestCase {
    func testOneTrackWritesMovieSRT() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try touchMovie(in: directory, name: "Movie.mp4")
        let engine = SubtitleEngine(reader: scripted(
            tracks: [text(1, "eng")],
            cues: [1: [cue("Hello", start: 1000, end: 2500)]]
        ))
        let outcome = try await engine.extract(file: movie, conflict: .overwrite)
        XCTAssertEqual(outcome.written.map(\.path), [directory.appendingPathComponent("Movie.srt").path])
        XCTAssertEqual(outcome.written.first?.cueCount, 1)
        let text = try String(contentsOf: URL(fileURLWithPath: outcome.written[0].path), encoding: .utf8)
        XCTAssertEqual(text, "1\n00:00:01,000 --> 00:00:02,500\nHello\n")
    }

    func testSeveralLanguagesAndABitmapTrack() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try touchMovie(in: directory, name: "Movie.mp4")
        var bitmap = text(3, "fra")
        bitmap.isExtractable = false
        bitmap.kind = .bitmap
        bitmap.codec = "mp4s"
        bitmap.skipReason = .bitmap
        let engine = SubtitleEngine(reader: scripted(
            tracks: [text(1, "eng"), text(2, "spa"), bitmap],
            cues: [
                1: [cue("Hello", start: 0, end: 1000)],
                2: [cue("Hola", start: 0, end: 1000)]
            ]
        ))
        let outcome = try await engine.extract(file: movie, conflict: .overwrite)
        let names = outcome.written.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted()
        XCTAssertEqual(names, ["Movie.eng.srt", "Movie.spa.srt"])
        XCTAssertEqual(outcome.skipped.map(\.reason), [.bitmap])
        let english = outcome.written.first { $0.languageCode == "eng" }!
        let body = try String(contentsOf: URL(fileURLWithPath: english.path), encoding: .utf8)
        XCTAssertTrue(body.contains("Hello"))
    }

    func testEveryCueForcedRenamesTheTrack() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try touchMovie(in: directory, name: "Movie.mp4")
        let engine = SubtitleEngine(reader: scripted(
            tracks: [text(1, "eng"), text(2, "eng")],
            cues: [
                1: [cue("Hello", start: 0, end: 1000)],
                2: [cue("Look", start: 0, end: 500, forced: true)]
            ]
        ))
        let outcome = try await engine.extract(file: movie, conflict: .overwrite)
        let names = Set(outcome.written.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        XCTAssertEqual(names, ["Movie.eng.srt", "Movie.eng.forced.srt"])
        let forced = try XCTUnwrap(outcome.written.first { $0.isForced })
        XCTAssertTrue(forced.path.hasSuffix("Movie.eng.forced.srt"))
    }

    func testSkipOverwriteAndKeepBoth() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try touchMovie(in: directory, name: "Movie.mp4")
        let existing = directory.appendingPathComponent("Movie.srt")
        try Data("keep".utf8).write(to: existing)
        let reader = scripted(tracks: [text(1, "eng")], cues: [1: [cue("Hello", start: 0, end: 1000)]])

        let skipped = try await SubtitleEngine(reader: reader).extract(file: movie, conflict: .skip)
        XCTAssertTrue(skipped.written.isEmpty)
        XCTAssertEqual(skipped.alreadyExists.map(\.path), [existing.path])
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep")

        let overwritten = try await SubtitleEngine(reader: reader).extract(file: movie, conflict: .overwrite)
        XCTAssertEqual(overwritten.written.map(\.path), [existing.path])
        XCTAssertTrue(try String(contentsOf: existing, encoding: .utf8).contains("Hello"))

        try Data("keep".utf8).write(to: existing)
        let both = try await SubtitleEngine(reader: reader).extract(file: movie, conflict: .keepBoth)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep")
        let extra = directory.appendingPathComponent("Movie (1).srt")
        XCTAssertEqual(both.written.map(\.path), [extra.path])
        XCTAssertTrue(try String(contentsOf: extra, encoding: .utf8).contains("Hello"))
    }

    func testNoTextTracksIsAnEmptyOutcome() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try touchMovie(in: directory, name: "Movie.mp4")
        var caption = text(1, "eng")
        caption.isExtractable = false
        caption.kind = .closedCaption
        caption.codec = "c608"
        caption.skipReason = .closedCaption
        let outcome = try await SubtitleEngine(reader: scripted(tracks: [caption], cues: [:]))
            .extract(file: movie)
        XCTAssertTrue(outcome.written.isEmpty)
        XCTAssertEqual(outcome.skipped.map(\.reason), [.closedCaption])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, ["Movie.mp4"])
    }

    func testProtectedFileThrowsAndMissingFileDoesNotAskTheReader() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try touchMovie(in: directory, name: "Movie.mp4")
        let protected = ProtectingReader()
        do {
            _ = try await SubtitleEngine(reader: protected).probe(file: movie)
            XCTFail("expected DRM")
        } catch SubtitleExtractionError.protectedContent {
        }
        do {
            _ = try await SubtitleEngine(reader: protected).probe(file: directory.appendingPathComponent("gone.mp4"))
            XCTFail("expected missing")
        } catch SubtitleExtractionError.fileNotFound {
        }
    }

    func testFailureWhileWritingRemovesPartialAndEarlierOutput() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try touchMovie(in: directory, name: "Movie.mp4")
        let flaky = FlakyDisk(succeedingWrites: 1)
        var storage = ExtractionStorage.live
        storage.write = { data, url in try flaky.write(data, url) }
        let engine = SubtitleEngine(
            reader: scripted(
                tracks: [text(1, "eng"), text(2, "spa")],
                cues: [
                    1: [cue("Hello", start: 0, end: 1000)],
                    2: [cue("Hola", start: 0, end: 1000)]
                ]
            ),
            storage: storage
        )
        do {
            _ = try await engine.extract(file: movie, conflict: .overwrite)
            XCTFail("expected the second write to fail")
        } catch SubtitleExtractionError.outputNotWritable {
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(left, ["Movie.mp4"])
    }

    func testExistingFileSurvivesALaterWriteFailure() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try touchMovie(in: directory, name: "Movie.mp4")
        let existing = directory.appendingPathComponent("Movie.eng.srt")
        try Data("keep".utf8).write(to: existing)
        let flaky = FlakyDisk(succeedingWrites: 1)
        var storage = ExtractionStorage.live
        storage.write = { data, url in try flaky.write(data, url) }
        let engine = SubtitleEngine(
            reader: scripted(
                tracks: [text(1, "eng"), text(2, "spa")],
                cues: [
                    1: [cue("Hello", start: 0, end: 1000)],
                    2: [cue("Hola", start: 0, end: 1000)]
                ]
            ),
            storage: storage
        )
        do {
            _ = try await engine.extract(file: movie, conflict: .overwrite)
            XCTFail("expected the second write to fail")
        } catch SubtitleExtractionError.outputNotWritable {
        }
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep")
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(left, ["Movie.eng.srt", "Movie.mp4"])
    }

    func testReaderFailureLeavesNoSRT() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try touchMovie(in: directory, name: "Movie.mp4")
        let engine = SubtitleEngine(reader: scripted(
            tracks: [text(1, "eng"), text(2, "spa")],
            cues: [1: [cue("Hello", start: 0, end: 1000)]],
            failureOnTrack: 2
        ))
        do {
            _ = try await engine.extract(file: movie, conflict: .overwrite)
            XCTFail("expected a read failure")
        } catch SubtitleExtractionError.malformedSample {
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(left, ["Movie.mp4"])
    }

    func testCancelDuringReadLeavesNoOutput() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try touchMovie(in: directory, name: "Movie.mp4")
        let reader = BlockingReader(track: text(1, "eng"), cue: cue("Hello", start: 0, end: 1000))
        let engine = SubtitleEngine(reader: reader)
        let task = Task {
            try await engine.extract(file: movie, conflict: .overwrite)
        }
        let deadline = Date().addingTimeInterval(5)
        while !reader.isWaiting, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(reader.isWaiting)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(left, ["Movie.mp4"])
    }

    func testProgressUsesTheMovieDuration() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try touchMovie(in: directory, name: "Movie.mp4")
        let engine = SubtitleEngine(reader: scripted(
            tracks: [text(1, "eng")],
            cues: [1: [cue("Hello", start: 0, end: 1000)]],
            duration: 10_000,
            sampleTimes: [1: [4000]]
        ))
        let box = ProgressBox()
        _ = try await engine.extract(file: movie, conflict: .overwrite) { completed, total in
            box.add(completed, total)
        }
        let ticks = box.ticks
        XCTAssertTrue(ticks.contains { $0 == (4000, 10000) }, "ticks \(ticks)")
        XCTAssertTrue(ticks.contains { $0 == (10000, 10000) }, "ticks \(ticks)")
    }

    func testLinuxLiveEngineRefusesToReadFiles() async throws {
        #if canImport(AVFoundation)
        throw XCTSkip("AVFoundation is the live reader on macOS.")
        #else
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try touchMovie(in: directory, name: "Movie.mp4")
        do {
            _ = try await SubtitleEngine().probe(file: movie)
            XCTFail("expected the macOS reader")
        } catch SubtitleExtractionError.unsupportedPlatform {
        }
        #endif
    }

    func testChosenTrackThatIsMissingThrows() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try touchMovie(in: directory, name: "Movie.mp4")
        let engine = SubtitleEngine(reader: scripted(tracks: [text(1, "eng")], cues: [:]))
        do {
            _ = try await engine.extract(file: movie, trackIDs: [9])
            XCTFail("expected a missing track")
        } catch let SubtitleExtractionError.unreadable(message) {
            XCTAssertTrue(message.contains("9"))
        }
    }

    private func scripted(
        tracks: [SubtitleTrack],
        cues: [Int: [SubtitleCue]],
        duration: Int = 0,
        sampleTimes: [Int: [Int]] = [:],
        failureOnTrack: Int? = nil
    ) -> ScriptedReader {
        ScriptedReader(
            inspection: MediaInspection(tracks: tracks, durationMilliseconds: duration),
            cuesByTrack: cues,
            sampleTimes: sampleTimes,
            failureOnTrack: failureOnTrack
        )
    }

    private func text(_ id: Int, _ language: String) -> SubtitleTrack {
        SubtitleTrack(
            id: id,
            languageCode: language,
            kind: .text,
            codec: "tx3g",
            isExtractable: true
        )
    }

    private func cue(_ text: String, start: Int, end: Int, forced: Bool = false) -> SubtitleCue {
        SubtitleCue(startMilliseconds: start, endMilliseconds: end, text: text, isForced: forced)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp4subrip-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touchMovie(in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        return url
    }
}

private struct ScriptedReader: SubtitleMediaReading {
    var inspection: MediaInspection
    var cuesByTrack: [Int: [SubtitleCue]]
    var sampleTimes: [Int: [Int]]
    var failureOnTrack: Int?

    func inspect(file: URL) async throws -> MediaInspection { inspection }

    func cues(
        file: URL,
        trackID: Int,
        onSampleTime: @escaping @Sendable (Int) -> Void
    ) -> AsyncThrowingStream<SubtitleCue, Error> {
        let cues = cuesByTrack[trackID] ?? []
        let times = sampleTimes[trackID] ?? []
        let fail = failureOnTrack == trackID
        return AsyncThrowingStream { continuation in
            for time in times { onSampleTime(time) }
            if fail {
                continuation.finish(throwing: SubtitleExtractionError.malformedSample)
                return
            }
            for cue in cues { continuation.yield(cue) }
            continuation.finish()
        }
    }
}

private struct ProtectingReader: SubtitleMediaReading {
    func inspect(file: URL) async throws -> MediaInspection {
        throw SubtitleExtractionError.protectedContent
    }

    func cues(
        file: URL,
        trackID: Int,
        onSampleTime: @escaping @Sendable (Int) -> Void
    ) -> AsyncThrowingStream<SubtitleCue, Error> {
        AsyncThrowingStream { $0.finish(throwing: SubtitleExtractionError.protectedContent) }
    }
}

private final class BlockingReader: SubtitleMediaReading, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting = false
    let track: SubtitleTrack
    let cue: SubtitleCue

    init(track: SubtitleTrack, cue: SubtitleCue) {
        self.track = track
        self.cue = cue
    }

    var isWaiting: Bool {
        lockedWaiting()
    }

    private func lockedWaiting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiting
    }

    private func markWaiting() {
        lock.lock()
        waiting = true
        lock.unlock()
    }

    func inspect(file: URL) async throws -> MediaInspection {
        MediaInspection(tracks: [track], durationMilliseconds: 5_000)
    }

    func cues(
        file: URL,
        trackID: Int,
        onSampleTime: @escaping @Sendable (Int) -> Void
    ) -> AsyncThrowingStream<SubtitleCue, Error> {
        let cue = self.cue
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(cue)
                self.markWaiting()
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

private final class FlakyDisk: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(succeedingWrites: Int) {
        remaining = succeedingWrites
    }

    func write(_ data: Data, _ url: URL) throws {
        lock.lock()
        let allow = remaining > 0
        if allow { remaining -= 1 }
        lock.unlock()
        if !allow { throw CocoaError(.fileWriteNoPermission) }
        try data.write(to: url, options: .atomic)
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(Int, Int)] = []

    func add(_ completed: Int, _ total: Int) {
        lock.lock()
        stored.append((completed, total))
        lock.unlock()
    }

    var ticks: [(Int, Int)] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
