import Foundation

/// SubRip text. Cues are separated by a blank line and times use a comma,
/// `HH:MM:SS,mmm`. Hours grow past 99 instead of wrapping.
enum SRTDocument {
    static func render(_ cues: [SubtitleCue]) -> String {
        var blocks: [String] = []
        for cue in cues {
            let text = normalize(cue.text)
            guard !text.isEmpty else { continue }
            let start = max(0, cue.startMilliseconds)
            let end = max(start + 1, cue.endMilliseconds)
            let index = blocks.count + 1
            blocks.append("\(index)\n\(stamp(start)) --> \(stamp(end))\n\(text)\n")
        }
        if blocks.isEmpty { return "" }
        return blocks.joined(separator: "\n")
    }

    /// A blank line would end the cue early, so collapsed blank lines inside the text stay one line.
    static func normalize(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        while text.contains("\n\n") {
            text = text.replacingOccurrences(of: "\n\n", with: "\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stamp(_ milliseconds: Int) -> String {
        let ms = max(0, milliseconds)
        let hours = ms / 3_600_000
        let minutes = (ms / 60_000) % 60
        let seconds = (ms / 1_000) % 60
        let millis = ms % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }
}
