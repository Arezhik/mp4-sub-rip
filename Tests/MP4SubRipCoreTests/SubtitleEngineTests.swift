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

    func testSameBaseNameInOneFolderFollowsTheExistsPolicy() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstFolder = root.appendingPathComponent("a", isDirectory: true)
        let secondFolder = root.appendingPathComponent("b", isDirectory: true)
        let output = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let movieA = try touchMovie(in: firstFolder, name: "Episode.mp4")
        let movieB = try touchMovie(in: secondFolder, name: "Episode.mp4")
        let reader = scripted(tracks: [text(1, "eng")], cues: [1: [cue("Hello", start: 0, end: 1000)]])

        let first = try await SubtitleEngine(reader: reader).extract(file: movieA, outputDirectory: output, conflict: .skip)
        XCTAssertEqual(first.written.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["Episode.srt"])

        let second = try await SubtitleEngine(reader: reader).extract(file: movieB, outputDirectory: output, conflict: .skip)
        XCTAssertTrue(second.written.isEmpty)
        XCTAssertEqual(second.alreadyExists.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["Episode.srt"])
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("Episode.srt"), encoding: .utf8).contains("Hello"), true)

        let numbered = try await SubtitleEngine(reader: reader).extract(file: movieB, outputDirectory: output, conflict: .keepBoth)
        XCTAssertEqual(numbered.written.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["Episode (1).srt"])
        XCTAssertTrue(try String(contentsOf: output.appendingPathComponent("Episode (1).srt"), encoding: .utf8).contains("Hello"))
    }

    func testNoTextTracksIsAnEmptyOutcome() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try touchMovie(in: directory, name: "Movie.mp4")
        var caption = text(1, "eng")
        caption.isExtractable = false
        caption.kind = .closedCaption
        caption.codec = "c708"
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

    func testMissingFFmpegSkipsTheClosedCaptionAndWritesNothing() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try touchMovie(in: directory, name: "Movie.mp4")
        var caption = text(1, "eng")
        caption.kind = .closedCaption
        caption.codec = "c608"
        let outcome = try await SubtitleEngine(reader: scripted(
            tracks: [caption],
            cues: [:],
            failureOnTrack: 1,
            failure: .needsFFmpeg
        )).extract(file: movie, conflict: .overwrite)
        XCTAssertTrue(outcome.written.isEmpty)
        XCTAssertEqual(outcome.skipped.map(\.reason), [.needsFFmpeg])
        XCTAssertEqual(outcome.skipped.first?.reason.message, "Closed-caption extraction needs ffmpeg. Install it with Homebrew, or choose it in Settings.")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, ["Movie.mp4"])
    }

    func testTextTrackStillWritesWhenClosedCaptionsNeedFFmpeg() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try touchMovie(in: directory, name: "Movie.mp4")
        var caption = text(2, "eng")
        caption.kind = .closedCaption
        caption.codec = "c608"
        let outcome = try await SubtitleEngine(reader: scripted(
            tracks: [text(1, "eng"), caption],
            cues: [1: [cue("Hello", start: 0, end: 1000)]],
            failureOnTrack: 2,
            failure: .needsFFmpeg
        )).extract(file: movie, conflict: .overwrite)
        XCTAssertEqual(outcome.written.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["Movie.srt"])
        XCTAssertEqual(outcome.skipped.map(\.reason), [.needsFFmpeg])
        let body = try String(contentsOf: URL(fileURLWithPath: outcome.written[0].path), encoding: .utf8)
        XCTAssertTrue(body.contains("Hello"))
    }

    func testClosedCaptionCuesUseTheSameNamingAsText() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try touchMovie(in: directory, name: "Movie.mp4")
        var caption = text(1, "eng")
        caption.kind = .closedCaption
        caption.codec = "c608"
        let outcome = try await SubtitleEngine(reader: scripted(
            tracks: [caption],
            cues: [1: [cue("Hello there", start: 1701, end: 4000)]]
        )).extract(file: movie, conflict: .overwrite)
        XCTAssertEqual(outcome.written.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["Movie.srt"])
        let body = try String(contentsOf: URL(fileURLWithPath: outcome.written[0].path), encoding: .utf8)
        XCTAssertEqual(body, "1\n00:00:01,701 --> 00:00:04,000\nHello there\n")
    }

    func testConcurrentSkipKeepBothAndOverwriteDoNotCorruptTheSameName() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstFolder = root.appendingPathComponent("a", isDirectory: true)
        let secondFolder = root.appendingPathComponent("b", isDirectory: true)
        let output = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let movieA = try touchMovie(in: firstFolder, name: "Episode.mp4")
        let movieB = try touchMovie(in: secondFolder, name: "Episode.mp4")
        let final = output.appendingPathComponent("Episode.srt")
        let numbered = output.appendingPathComponent("Episode (1).srt")

        let reservation = OutputReservation()
        let hold = FirstWriteHold()
        let storage = hold.storage()
        let engineA = SubtitleEngine(reader: reader(text: "Alpha"), storage: storage)
        let engineB = SubtitleEngine(reader: reader(text: "Beta"), storage: storage)
        let box = OutcomeBox()
        Task.detached {
            do {
                box.add(.success(try await engineA.extract(file: movieA, outputDirectory: output, conflict: .skip, reservation: reservation)))
            } catch {
                box.add(.failure(error))
            }
        }
        Task.detached {
            do {
                box.add(.success(try await engineB.extract(file: movieB, outputDirectory: output, conflict: .skip, reservation: reservation)))
            } catch {
                box.add(.failure(error))
            }
        }
        try await hold.waitUntilEntered()
        let whileHeld = try await box.waitForCount(1, timeout: 3)
        let skipped = try whileHeld[0].get()
        XCTAssertTrue(skipped.written.isEmpty)
        XCTAssertEqual(skipped.alreadyExists.map(\.path), [final.path])
        XCTAssertEqual(hold.writes, 1)
        hold.unblock()
        let both = try await box.waitForCount(2, timeout: 3)
        let wrote = try both.map { try $0.get() }.first { !$0.written.isEmpty }
        let written = try XCTUnwrap(wrote)
        XCTAssertEqual(written.written.map(\.path), [final.path])
        let body = try String(contentsOf: final, encoding: .utf8)
        XCTAssertTrue(body.contains("Alpha") || body.contains("Beta"))
        XCTAssertFalse(body.contains("Alpha") && body.contains("Beta"))
        XCTAssertFalse(reservation.isReserved(final.path))
        try assertNoPartials(in: output)

        try? FileManager.default.removeItem(at: final)
        let keep = OutputReservation()
        let keepHold = FirstWriteHold()
        let keepStorage = keepHold.storage()
        let keepA = SubtitleEngine(reader: reader(text: "Alpha"), storage: keepStorage)
        let keepB = SubtitleEngine(reader: reader(text: "Beta"), storage: keepStorage)
        let keepBox = OutcomeBox()
        Task.detached {
            do {
                keepBox.add(.success(try await keepA.extract(file: movieA, outputDirectory: output, conflict: .keepBoth, reservation: keep)))
            } catch {
                keepBox.add(.failure(error))
            }
        }
        Task.detached {
            do {
                keepBox.add(.success(try await keepB.extract(file: movieB, outputDirectory: output, conflict: .keepBoth, reservation: keep)))
            } catch {
                keepBox.add(.failure(error))
            }
        }
        try await keepHold.waitUntilEntered()
        let numberedResult = try await keepBox.waitForCount(1, timeout: 3)
        let numberedOutcome = try numberedResult[0].get()
        XCTAssertEqual(
            numberedOutcome.written.map { URL(fileURLWithPath: $0.path).lastPathComponent },
            ["Episode (1).srt"]
        )
        keepHold.unblock()
        _ = try await keepBox.waitForCount(2, timeout: 3)
        let baseBody = try String(contentsOf: final, encoding: .utf8)
        let numberedBody = try String(contentsOf: numbered, encoding: .utf8)
        XCTAssertTrue(baseBody.contains("Alpha") || baseBody.contains("Beta"))
        XCTAssertTrue(numberedBody.contains("Alpha") || numberedBody.contains("Beta"))
        XCTAssertNotEqual(baseBody, numberedBody)
        XCTAssertFalse(keep.isReserved(final.path))
        XCTAssertFalse(keep.isReserved(numbered.path))
        try assertNoPartials(in: output)

        try? FileManager.default.removeItem(at: final)
        try? FileManager.default.removeItem(at: numbered)
        let overwrite = OutputReservation()
        let moves = MoveOverlap()
        let overwriteHold = FirstWriteHold(moves: moves)
        let overwriteStorage = overwriteHold.storage()
        let overA = SubtitleEngine(reader: reader(text: "Alpha"), storage: overwriteStorage)
        let overB = SubtitleEngine(reader: reader(text: "Beta"), storage: overwriteStorage)
        let overBox = OutcomeBox()
        Task.detached {
            do {
                overBox.add(.success(try await overA.extract(file: movieA, outputDirectory: output, conflict: .overwrite, reservation: overwrite)))
            } catch {
                overBox.add(.failure(error))
            }
        }
        Task.detached {
            do {
                overBox.add(.success(try await overB.extract(file: movieB, outputDirectory: output, conflict: .overwrite, reservation: overwrite)))
            } catch {
                overBox.add(.failure(error))
            }
        }
        try await overwriteHold.waitUntilEntered()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(overwriteHold.writes, 1)
        XCTAssertTrue(overBox.snapshot().isEmpty)
        overwriteHold.unblock()
        let overwritten = try await overBox.waitForCount(2, timeout: 3)
        XCTAssertEqual(try overwritten.map { try $0.get() }.flatMap(\.written).count, 2)
        XCTAssertEqual(moves.maxActive, 1)
        let finalBody = try String(contentsOf: final, encoding: .utf8)
        XCTAssertTrue(finalBody.hasPrefix("1\n"))
        let hasAlpha = finalBody.contains("Alpha")
        let hasBeta = finalBody.contains("Beta")
        XCTAssertNotEqual(hasAlpha, hasBeta)
        XCTAssertFalse(overwrite.isReserved(final.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: numbered.path))
        try assertNoPartials(in: output)
    }

    func testReservationReleasesWhenWritingFails() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try touchMovie(in: directory, name: "Movie.mp4")
        let final = directory.appendingPathComponent("Movie.srt")
        let reservation = OutputReservation()
        let flaky = FlakyDisk(succeedingWrites: 0)
        var storage = ExtractionStorage.live
        storage.write = { data, url in try flaky.write(data, url) }
        let engine = SubtitleEngine(reader: reader(text: "Alpha"), storage: storage)
        do {
            _ = try await engine.extract(file: movie, conflict: .skip, reservation: reservation)
            XCTFail("expected the write to fail")
        } catch SubtitleExtractionError.outputNotWritable {
        }
        XCTAssertFalse(reservation.isReserved(final.path))
        let recovered = try await SubtitleEngine(reader: reader(text: "Beta")).extract(
            file: movie,
            conflict: .skip,
            reservation: reservation
        )
        XCTAssertEqual(recovered.written.map(\.path), [final.path])
        XCTAssertTrue(try String(contentsOf: final, encoding: .utf8).contains("Beta"))
        XCTAssertFalse(reservation.isReserved(final.path))
    }

    func testReservationReleasesWhenCancelledDuringTheWrite() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try touchMovie(in: directory, name: "Movie.mp4")
        let final = directory.appendingPathComponent("Movie.srt")
        let reservation = OutputReservation()
        let gate = CancelGate()
        var storage = ExtractionStorage.live
        storage.write = { data, url in try gate.write(data, url) }
        let engine = SubtitleEngine(reader: reader(text: "Alpha"), storage: storage)
        let task = Task.detached {
            try await engine.extract(file: movie, conflict: .overwrite, reservation: reservation)
        }
        try await gate.waitUntilEntered()
        XCTAssertTrue(reservation.isReserved(final.path))
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(reservation.isReserved(final.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        let recovered = try await SubtitleEngine(reader: reader(text: "Beta")).extract(
            file: movie,
            conflict: .overwrite,
            reservation: reservation
        )
        XCTAssertEqual(recovered.written.map(\.path), [final.path])
        XCTAssertTrue(try String(contentsOf: final, encoding: .utf8).contains("Beta"))
        XCTAssertFalse(reservation.isReserved(final.path))
        try assertNoPartials(in: directory)
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

    private func reader(text: String) -> ScriptedReader {
        scripted(tracks: [textTrack(1, "eng")], cues: [1: [cue(text, start: 0, end: 1000)]])
    }

    private func textTrack(_ id: Int, _ language: String) -> SubtitleTrack {
        text(id, language)
    }

    private func assertNoPartials(in directory: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.contains(".partial") })
    }

    private func scripted(
        tracks: [SubtitleTrack],
        cues: [Int: [SubtitleCue]],
        duration: Int = 0,
        sampleTimes: [Int: [Int]] = [:],
        failureOnTrack: Int? = nil,
        failure: SubtitleExtractionError? = nil
    ) -> ScriptedReader {
        ScriptedReader(
            inspection: MediaInspection(tracks: tracks, durationMilliseconds: duration),
            cuesByTrack: cues,
            sampleTimes: sampleTimes,
            failureOnTrack: failureOnTrack,
            failure: failure
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
    var failure: SubtitleExtractionError?

    func inspect(file: URL) async throws -> MediaInspection { inspection }

    func cues(
        file: URL,
        trackID: Int,
        onSampleTime: @escaping @Sendable (Int) -> Void
    ) -> AsyncThrowingStream<SubtitleCue, Error> {
        let cues = cuesByTrack[trackID] ?? []
        let times = sampleTimes[trackID] ?? []
        let fail = failureOnTrack == trackID
        let thrown = failure
        return AsyncThrowingStream { continuation in
            for time in times { onSampleTime(time) }
            if fail {
                continuation.finish(throwing: thrown ?? SubtitleExtractionError.malformedSample)
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

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<ExtractionOutcome, Error>] = []

    func add(_ value: Result<ExtractionOutcome, Error>) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Result<ExtractionOutcome, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func waitForCount(_ count: Int, timeout: TimeInterval) async throws -> [Result<ExtractionOutcome, Error>] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = snapshot()
            if current.count >= count { return current }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(count) extraction results, saw \(snapshot().count)")
        return snapshot()
    }
}

private final class MoveOverlap: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maxActive = 0

    func begin() {
        lock.lock()
        active += 1
        maxActive = max(maxActive, active)
        lock.unlock()
    }

    func end() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}

private final class FirstWriteHold: @unchecked Sendable {
    private let lock = NSLock()
    private var didHold = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let release = DispatchSemaphore(value: 0)
    private let moves: MoveOverlap?
    private(set) var writes = 0

    init(moves: MoveOverlap? = nil) {
        self.moves = moves
    }

    func storage() -> ExtractionStorage {
        var storage = ExtractionStorage.live
        storage.write = { [self] data, url in
            try self.write(data, url)
        }
        storage.move = { [self] partial, final in
            self.moves?.begin()
            defer { self.moves?.end() }
            try ExtractionStorage.live.move(partial, final)
        }
        return storage
    }

    func write(_ data: Data, _ url: URL) throws {
        lock.lock()
        writes += 1
        let hold = !didHold
        if hold { didHold = true }
        let pending = hold ? waiters : []
        if hold { waiters.removeAll() }
        lock.unlock()
        if hold {
            for waiter in pending { waiter.resume() }
            _ = release.wait(timeout: .now() + 5)
        }
        try data.write(to: url, options: .atomic)
    }

    func waitUntilEntered() async throws {
        let already: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return didHold
        }()
        if already { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if didHold {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func unblock() {
        release.signal()
    }
}

private final class CancelGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func write(_ data: Data, _ url: URL) throws {
        lock.lock()
        entered = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
        for _ in 0..<400 {
            if Task.isCancelled { throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw CancellationError()
    }

    func waitUntilEntered() async throws {
        let already: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return entered
        }()
        if already { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if entered {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
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
