import XCTest
@testable import MP4SubRipCore

final class ClosedCaptionTests: XCTestCase {
    func testCleanupStripsDecoderArtifactsAndKeepsItalics() throws {
        let raw = """
        1
        00:00:01,701 --> 00:00:04,000
        {\\an7}<font face="Monospace" color="#ffffff">Hello\\hthere</font>

        2
        00:00:04,500 --> 00:00:06,000
        <font color="#ffffff"><i>Real italics</i></font>

        3
        00:00:06,000 --> 00:00:07,000
        {\\an8}<font face="Sans"> </font>
        """
        let cleaned = ClosedCaptionText.clean(raw)
        XCTAssertFalse(cleaned.contains("{\\an7}"))
        XCTAssertFalse(cleaned.contains("{\\an8}"))
        XCTAssertFalse(cleaned.contains("<font"))
        XCTAssertFalse(cleaned.contains("</font>"))
        XCTAssertFalse(cleaned.contains("\\h"))
        XCTAssertTrue(cleaned.contains("<i>Real italics</i>"))

        let cues = try SRTDocument.parse(cleaned)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].startMilliseconds, 1_701)
        XCTAssertEqual(cues[0].endMilliseconds, 4_000)
        XCTAssertEqual(cues[0].text, "Hello there")
        XCTAssertEqual(cues[1].text, "<i>Real italics</i>")
        XCTAssertEqual(
            SRTDocument.render(cues),
            "1\n00:00:01,701 --> 00:00:04,000\nHello there\n\n2\n00:00:04,500 --> 00:00:06,000\n<i>Real italics</i>\n"
        )
    }

    func testSecondPositionMarkerBecomesALineBreak() throws {
        let single = ClosedCaptionText.clean("{\\an7}<font face=\"Monospace\">Hello</font>")
        XCTAssertEqual(single, "Hello")
        XCTAssertFalse(single.contains("\n"))

        // No second marker, so punctuation stays glued. There is no fallback.
        XCTAssertEqual(ClosedCaptionText.clean("right?Let’s face it."), "right?Let’s face it.")

        let glued = ClosedCaptionText.clean(
            "<font face=\"Monospace\">{\\an7}right?</font><font face=\"Monospace\">{\\an7}Let’s face it.</font>"
        )
        XCTAssertEqual(glued, "right?\nLet’s face it.")

        let beeps = ClosedCaptionText.clean(
            "<font face=\"Monospace\">{\\an7}We’ll be in touch.</font><font face=\"Monospace\">{\\an7}[ Beeps ]</font><font face=\"Monospace\">{\\an7}[ Beeps ]</font>"
        )
        XCTAssertEqual(beeps, "We’ll be in touch.\n[ Beeps ]\n[ Beeps ]")

        let raw = """
        1
        00:00:01,000 --> 00:00:02,000
        {\\an7}<font face="Monospace">One</font>

        2
        00:00:02,000 --> 00:00:03,000
        <font face="Monospace">{\\an7}right?</font><font face="Monospace">{\\an7}Let’s face it.</font>
        """
        let cues = try SRTDocument.parse(ClosedCaptionText.clean(raw))
        XCTAssertEqual(cues.map(\.text), ["One", "right?\nLet’s face it."])
    }

    func testIdenticalWindowPairMerges() throws {
        let cues = [
            SubtitleCue(startMilliseconds: 1_000, endMilliseconds: 3_000, text: "Right?"),
            SubtitleCue(startMilliseconds: 1_000, endMilliseconds: 3_000, text: "Let’s face it.")
        ]
        let tidy = try ClosedCaptionTiming.tidy(cues)
        XCTAssertEqual(tidy, [
            SubtitleCue(startMilliseconds: 1_000, endMilliseconds: 3_000, text: "Right?\nLet’s face it.")
        ])
    }

    func testSameStartDifferentEndBecomesTwoSlices() throws {
        let cues = [
            SubtitleCue(startMilliseconds: 0, endMilliseconds: 2_000, text: "Hello"),
            SubtitleCue(startMilliseconds: 0, endMilliseconds: 1_000, text: "World")
        ]
        let tidy = try ClosedCaptionTiming.tidy(cues)
        XCTAssertEqual(tidy, [
            SubtitleCue(startMilliseconds: 0, endMilliseconds: 1_000, text: "Hello\nWorld"),
            SubtitleCue(startMilliseconds: 1_000, endMilliseconds: 2_000, text: "Hello")
        ])
    }

    func testAdjacentIdenticalSlicesJoin() throws {
        let cues = [
            SubtitleCue(startMilliseconds: 0, endMilliseconds: 3_000, text: "Hello"),
            SubtitleCue(startMilliseconds: 1_000, endMilliseconds: 2_000, text: "World"),
            SubtitleCue(startMilliseconds: 2_000, endMilliseconds: 3_000, text: "World")
        ]
        let tidy = try ClosedCaptionTiming.tidy(cues)
        XCTAssertEqual(tidy, [
            SubtitleCue(startMilliseconds: 0, endMilliseconds: 1_000, text: "Hello"),
            SubtitleCue(startMilliseconds: 1_000, endMilliseconds: 3_000, text: "Hello\nWorld")
        ])
    }

    func testNonOverlappingCuesAreUnchanged() throws {
        let cues = [
            SubtitleCue(startMilliseconds: 0, endMilliseconds: 1_000, text: "Same", isForced: true),
            SubtitleCue(startMilliseconds: 1_000, endMilliseconds: 2_500, text: "Same"),
            SubtitleCue(startMilliseconds: 4_000, endMilliseconds: 6_000, text: "Later")
        ]
        XCTAssertEqual(try ClosedCaptionTiming.tidy(cues), cues)
    }

    func testShortLastCueIsExtendedAndCapped() throws {
        let earlier = SubtitleCue(startMilliseconds: 0, endMilliseconds: 2_000, text: "Earlier")
        let brief = SubtitleCue(startMilliseconds: 2_000, endMilliseconds: 2_600, text: "Hi")
        let extended = try ClosedCaptionTiming.tidy([earlier, brief])
        XCTAssertEqual(extended[0], earlier)
        XCTAssertEqual(extended[1].startMilliseconds, 2_000)
        XCTAssertEqual(extended[1].endMilliseconds, 3_500)
        XCTAssertEqual(extended[1].text, "Hi")

        let italics = "<i>" + String(repeating: "A", count: 30) + "</i>"
        let styled = try ClosedCaptionTiming.tidy([
            SubtitleCue(startMilliseconds: 0, endMilliseconds: 400, text: italics)
        ])
        XCTAssertEqual(styled[0].endMilliseconds, 1_800)
        XCTAssertEqual(styled[0].text, italics)

        let lines = String(repeating: "B", count: 25) + "\n" + String(repeating: "C", count: 25)
        let wrapped = try ClosedCaptionTiming.tidy([
            SubtitleCue(startMilliseconds: 0, endMilliseconds: 200, text: lines)
        ])
        XCTAssertEqual(wrapped[0].endMilliseconds, 3_000)

        let longText = String(repeating: "A", count: 120)
        let capped = try ClosedCaptionTiming.tidy([
            SubtitleCue(startMilliseconds: 0, endMilliseconds: 100, text: longText)
        ])
        XCTAssertEqual(capped[0].endMilliseconds, 6_000)
        XCTAssertEqual(capped[0].text, longText)

        let atMovieEnd = try ClosedCaptionTiming.tidy(
            [SubtitleCue(startMilliseconds: 10_000, endMilliseconds: 10_400, text: longText)],
            movieDurationMilliseconds: 12_000
        )
        XCTAssertEqual(atMovieEnd[0].endMilliseconds, 12_000)

        let alreadyAtEnd = try ClosedCaptionTiming.tidy(
            [SubtitleCue(startMilliseconds: 1_000, endMilliseconds: 1_600, text: "Hi")],
            movieDurationMilliseconds: 1_600
        )
        XCTAssertEqual(alreadyAtEnd[0].endMilliseconds, 1_600)

        let atOneSecond = [SubtitleCue(startMilliseconds: 0, endMilliseconds: 1_000, text: "Hi")]
        XCTAssertEqual(try ClosedCaptionTiming.tidy(atOneSecond), atOneSecond)
        let longer = [SubtitleCue(startMilliseconds: 0, endMilliseconds: 4_400, text: "Hi")]
        XCTAssertEqual(try ClosedCaptionTiming.tidy(longer), longer)

        let shortInTheMiddle = [
            SubtitleCue(startMilliseconds: 0, endMilliseconds: 500, text: "Hi"),
            SubtitleCue(startMilliseconds: 500, endMilliseconds: 2_000, text: "Later")
        ]
        XCTAssertEqual(try ClosedCaptionTiming.tidy(shortInTheMiddle), shortInTheMiddle)
    }

    func testJeannieStyleFixtureStaysByteIdentical() throws {
        let raw = """
        1
        00:00:01,701 --> 00:00:04,000
        {\\an7}<font face="Monospace" color="#ffffff">Hello\\hthere</font>

        2
        00:00:04,500 --> 00:00:06,500
        {\\an7}<font face="Monospace"><i>Next line</i></font>

        3
        00:00:07,000 --> 00:24:50,269
        {\\an7}<font face="Sans">End</font>
        """
        let parsed = try SRTDocument.parse(ClosedCaptionText.clean(raw))
        let tidied = try ClosedCaptionTiming.tidy(parsed)
        let expected = [
            SubtitleCue(startMilliseconds: 1_701, endMilliseconds: 4_000, text: "Hello there"),
            SubtitleCue(startMilliseconds: 4_500, endMilliseconds: 6_500, text: "<i>Next line</i>"),
            SubtitleCue(startMilliseconds: 7_000, endMilliseconds: 1_490_269, text: "End")
        ]
        XCTAssertEqual(parsed, expected)
        XCTAssertEqual(tidied, parsed)
        XCTAssertEqual(SRTDocument.render(tidied), SRTDocument.render(parsed))
    }

    func testExtractTidiesGluedCuesAndAShortEnding() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("Movie.mp4")
        XCTAssertTrue(FileManager.default.createFile(atPath: movie.path, contents: Data()))
        let raw = """
        1
        00:00:01,000 --> 00:00:02,000
        {\\an7}<font face="Monospace">One</font>

        2
        00:00:01,000 --> 00:00:02,000
        {\\an7}<font face="Monospace">Two</font>

        3
        00:00:05,000 --> 00:00:05,400
        <font face="Monospace">{\\an7}touch.</font><font face="Monospace">{\\an7}[ Beeps ]</font><font face="Monospace">{\\an7}[ Beeps ]</font>
        """
        let runner = FFmpegRunner(
            locate: { "/opt/homebrew/bin/ffmpeg" },
            run: { _, arguments in
                guard let output = arguments.last else {
                    return ToolCommandResult(status: 1, standardOutput: Data(), standardError: Data())
                }
                try Data(raw.utf8).write(to: URL(fileURLWithPath: output))
                return ToolCommandResult(status: 0, standardOutput: Data(), standardError: Data())
            }
        )
        let cues = try await FFmpegClosedCaptions.extract(
            file: movie,
            subtitleIndex: 0,
            runner: runner,
            onSampleTime: { _ in }
        )
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].startMilliseconds, 1_000)
        XCTAssertEqual(cues[0].endMilliseconds, 2_000)
        XCTAssertEqual(cues[0].text, "One\nTwo")
        XCTAssertEqual(cues[1].startMilliseconds, 5_000)
        XCTAssertEqual(cues[1].text, "touch.\n[ Beeps ]\n[ Beeps ]")
        // 6 + 9 + 9 visible characters → 1,440 ms, which the 1,500 ms floor wins.
        XCTAssertEqual(cues[1].endMilliseconds, 6_500)
    }

    func testSubtitleIndexFollowsTrackIDOrder() {
        let tracks = [
            SubtitleTrack(id: 5, languageCode: "eng", kind: .closedCaption, codec: "c608", isExtractable: true),
            SubtitleTrack(id: 2, languageCode: "eng", kind: .text, codec: "tx3g", isExtractable: true),
            SubtitleTrack(id: 9, languageCode: "eng", kind: .closedCaption, codec: "c708", isExtractable: false)
        ]
        XCTAssertEqual(FFmpegClosedCaptions.subtitleStreamIndex(of: 2, in: tracks), 0)
        XCTAssertEqual(FFmpegClosedCaptions.subtitleStreamIndex(of: 5, in: tracks), 1)
        XCTAssertEqual(FFmpegClosedCaptions.subtitleStreamIndex(of: 9, in: tracks), 2)
        XCTAssertEqual(FFmpegClosedCaptions.subtitleStreamIndex(of: 3, in: [
            SubtitleTrack(id: 3, languageCode: "eng", kind: .closedCaption, codec: "c608", isExtractable: true)
        ]), 0)
    }

    func testArgumentsMapTheSubtitleStreamAndDoNotUseLavfi() {
        let arguments = FFmpegClosedCaptions.arguments(
            inputPath: "/tmp/Movie.mp4",
            subtitleIndex: 0,
            outputPath: "/tmp/out.srt"
        )
        XCTAssertEqual(arguments.first, "-nostdin")
        XCTAssertTrue(arguments.contains("-i"))
        XCTAssertTrue(arguments.contains("/tmp/Movie.mp4"))
        XCTAssertTrue(arguments.contains("-map"))
        XCTAssertTrue(arguments.contains("0:s:0"))
        XCTAssertTrue(arguments.contains("-c:s"))
        XCTAssertTrue(arguments.contains("srt"))
        XCTAssertEqual(arguments.last, "/tmp/out.srt")
        let joined = arguments.joined(separator: " ")
        XCTAssertFalse(joined.contains("subcc"))
        XCTAssertFalse(joined.contains("movie="))
        XCTAssertFalse(joined.contains("ccextractor"))
        XCTAssertFalse(joined.contains("lavfi"))
    }

    func testExtractCleansTheFileFFmpegWrote() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("Movie.mp4")
        XCTAssertTrue(FileManager.default.createFile(atPath: movie.path, contents: Data()))
        let raw = "1\n00:00:01,701 --> 00:24:50,269\n{\\an7}<font face=\"Monospace\">Hi\\hthere</font>\n"
        let seen = ArgumentBox()
        let runner = FFmpegRunner(
            locate: { "/opt/homebrew/bin/ffmpeg" },
            run: { executable, arguments in
                seen.store(executable, arguments)
                guard let output = arguments.last else {
                    return ToolCommandResult(status: 1, standardOutput: Data(), standardError: Data())
                }
                try Data(raw.utf8).write(to: URL(fileURLWithPath: output))
                return ToolCommandResult(status: 0, standardOutput: Data(), standardError: Data())
            }
        )
        let cues = try await FFmpegClosedCaptions.extract(
            file: movie,
            subtitleIndex: 0,
            runner: runner,
            onSampleTime: { _ in }
        )
        let actual = try XCTUnwrap(seen.arguments)
        XCTAssertEqual(seen.executable, "/opt/homebrew/bin/ffmpeg")
        XCTAssertEqual(actual, FFmpegClosedCaptions.arguments(
            inputPath: movie.path,
            subtitleIndex: 0,
            outputPath: actual.last ?? ""
        ))
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Hi there")
        XCTAssertEqual(cues[0].startMilliseconds, 1_701)
        XCTAssertEqual(cues[0].endMilliseconds, 1_490_269)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(left, ["Movie.mp4"])
        if let output = seen.arguments?.last {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output))
        }
    }

    func testMissingFFmpegThrowsAndAFailureLeavesNoFile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("Movie.mp4")
        XCTAssertTrue(FileManager.default.createFile(atPath: movie.path, contents: Data()))
        let missing = FFmpegRunner(locate: { nil }, run: { _, _ in
            ToolCommandResult(status: 0, standardOutput: Data(), standardError: Data())
        })
        do {
            _ = try await FFmpegClosedCaptions.extract(
                file: movie,
                subtitleIndex: 0,
                runner: missing,
                onSampleTime: { _ in }
            )
            XCTFail("expected ffmpeg to be required")
        } catch SubtitleExtractionError.needsFFmpeg {
        }

        let seen = ArgumentBox()
        let failing = FFmpegRunner(
            locate: { "/opt/homebrew/bin/ffmpeg" },
            run: { _, arguments in
                seen.store("/opt/homebrew/bin/ffmpeg", arguments)
                if let output = arguments.last {
                    try Data("partial".utf8).write(to: URL(fileURLWithPath: output))
                }
                return ToolCommandResult(status: 1, standardOutput: Data(), standardError: Data("bad".utf8))
            }
        )
        do {
            _ = try await FFmpegClosedCaptions.extract(
                file: movie,
                subtitleIndex: 0,
                runner: failing,
                onSampleTime: { _ in }
            )
            XCTFail("expected ffmpeg to fail")
        } catch let ToolFailure.failed(tool, status) {
            XCTAssertEqual(tool, "ffmpeg")
            XCTAssertEqual(status, 1)
        }
        if let output = seen.arguments?.last {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output))
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(left, ["Movie.mp4"])
    }

    func testCancelRemovesTheTemporarySRT() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("Movie.mp4")
        XCTAssertTrue(FileManager.default.createFile(atPath: movie.path, contents: Data()))
        let seen = ArgumentBox()
        let runner = FFmpegRunner(
            locate: { "/opt/homebrew/bin/ffmpeg" },
            run: { _, arguments in
                seen.store("/opt/homebrew/bin/ffmpeg", arguments)
                if let output = arguments.last {
                    try Data("partial".utf8).write(to: URL(fileURLWithPath: output))
                }
                throw CancellationError()
            }
        )
        do {
            _ = try await FFmpegClosedCaptions.extract(
                file: movie,
                subtitleIndex: 0,
                runner: runner,
                onSampleTime: { _ in }
            )
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
        if let output = seen.arguments?.last {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output))
        }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp4subrip-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class ArgumentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedExecutable: String?
    private var storedArguments: [String]?

    func store(_ executable: String, _ arguments: [String]) {
        lock.lock()
        storedExecutable = executable
        storedArguments = arguments
        lock.unlock()
    }

    var executable: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedExecutable
    }

    var arguments: [String]? {
        lock.lock()
        defer { lock.unlock() }
        return storedArguments
    }
}
