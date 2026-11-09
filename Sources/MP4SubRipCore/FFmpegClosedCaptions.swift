import Foundation

// Discrete EIA-608 (`c608`) is extracted with ffmpeg's subtitle mapper.
// `ffmpeg -map 0:s:N -c:s srt` is the path that worked on Arezhik's files.
// The caption-adaptor spike compares against this cleaned SRT and does not
// replace it. CCExtractor and lavfi `movie=…[out0+subcc]` are not used.
// CEA-708 and captions that live only in the video bitstream never reach this file.

struct FFmpegRunner: Sendable {
    var locate: @Sendable () -> String?
    var run: @Sendable (String, [String]) async throws -> ToolCommandResult

    static let live = FFmpegRunner(
        locate: { ExternalTool.locate()?["ffmpeg"] },
        run: { executable, arguments in
            try await ToolCommand.run(executable: executable, arguments: arguments)
        }
    )
}

enum FFmpegClosedCaptions {
    static let codec = "c608"

    /// ffmpeg's `0:s:N` counts subtitle streams in file order. The tracks we
    /// discover are those streams, and their ids increase in that order.
    static func subtitleStreamIndex(of trackID: Int, in tracks: [SubtitleTrack]) -> Int {
        tracks.map(\.id).sorted().firstIndex(of: trackID) ?? 0
    }

    /// Output path is last, which is where ffmpeg expects the destination.
    static func arguments(inputPath: String, subtitleIndex: Int, outputPath: String) -> [String] {
        [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", inputPath,
            "-map", "0:s:\(subtitleIndex)",
            "-c:s", "srt",
            "-f", "srt",
            outputPath
        ]
    }

    /// Writes ffmpeg's SRT to a temporary file, cleans it, and returns cues.
    /// The temporary file is removed on success, failure, and cancel. The
    /// engine writes the final SRT, so naming and conflict handling stay there.
    static func extract(
        file: URL,
        subtitleIndex: Int,
        runner: FFmpegRunner = .live,
        onSampleTime: @escaping @Sendable (Int) -> Void
    ) async throws -> [SubtitleCue] {
        try Task.checkCancellation()
        guard let ffmpeg = runner.locate() else {
            throw SubtitleExtractionError.needsFFmpeg
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp4subrip-c608-\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: output) }
        let arguments = arguments(
            inputPath: file.path,
            subtitleIndex: subtitleIndex,
            outputPath: output.path
        )
        let result = try await runner.run(ffmpeg, arguments)
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw ToolFailure.failed(tool: "ffmpeg", status: result.status)
        }
        let data: Data
        do {
            data = try Data(contentsOf: output)
        } catch {
            throw SubtitleExtractionError.unreadable("ffmpeg did not write a subtitle file.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SubtitleExtractionError.unreadable("ffmpeg wrote subtitles that are not UTF-8.")
        }
        let cues = try SRTDocument.parse(ClosedCaptionText.clean(text))
        for cue in cues {
            try Task.checkCancellation()
            onSampleTime(cue.startMilliseconds)
        }
        return cues
    }
}
