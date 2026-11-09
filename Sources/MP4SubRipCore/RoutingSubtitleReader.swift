import Foundation

// tx3g stays on AVFoundation. A discrete `c608` track is the one case that
// goes to ffmpeg. This file is the seam `SubtitleEngine()` uses on macOS.

#if canImport(AVFoundation)
struct RoutingSubtitleReader: SubtitleMediaReading {
    private let text = AVFoundationSubtitleReader()

    func inspect(file: URL) async throws -> MediaInspection {
        try await text.inspect(file: file)
    }

    func cues(
        file: URL,
        trackID: Int,
        onSampleTime: @escaping @Sendable (Int) -> Void
    ) -> AsyncThrowingStream<SubtitleCue, Error> {
        let text = self.text
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let inspection = try await text.inspect(file: file)
                    if let track = inspection.tracks.first(where: { $0.id == trackID }),
                       track.codec == FFmpegClosedCaptions.codec {
                        let index = FFmpegClosedCaptions.subtitleStreamIndex(of: trackID, in: inspection.tracks)
                        let cues = try await FFmpegClosedCaptions.extract(
                            file: file,
                            subtitleIndex: index,
                            onSampleTime: onSampleTime
                        )
                        for cue in cues {
                            try Task.checkCancellation()
                            continuation.yield(cue)
                        }
                        continuation.finish()
                    } else {
                        for try await cue in text.cues(file: file, trackID: trackID, onSampleTime: onSampleTime) {
                            try Task.checkCancellation()
                            continuation.yield(cue)
                        }
                        continuation.finish()
                    }
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
#endif
