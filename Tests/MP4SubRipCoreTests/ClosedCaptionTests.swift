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
