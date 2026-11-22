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

    /// A blank line would end the cue early, and many players also treat a line of only spaces
    /// or tabs as blank. Both kinds are dropped, so the cue's text stays together.
    static func normalize(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cues ffmpeg wrote. A block that is not a cue is ignored. Empty text is dropped.
    static func parse(_ text: String) throws -> [SubtitleCue] {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{feff}") {
            text.removeFirst()
        }
        var cues: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            try Task.checkCancellation()
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let lines = trimmed.components(separatedBy: "\n")
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            guard let times = cueTimes(lines[timingIndex]) else { continue }
            let body = lines.dropFirst(timingIndex + 1).joined(separator: "\n")
            let normalized = normalize(body)
            if normalized.isEmpty { continue }
            cues.append(SubtitleCue(
                startMilliseconds: times.start,
                endMilliseconds: times.end,
                text: normalized
            ))
        }
        return cues
    }

    private static func cueTimes(_ line: String) -> (start: Int, end: Int)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2, let start = milliseconds(parts[0]), let end = milliseconds(parts[1]) else {
            return nil
        }
        return (start, end)
    }

    /// `HH:MM:SS,mmm`, with a dot accepted in place of the comma. Extra tokens
    /// after the stamp (positioning) are ignored.
    static func milliseconds(_ raw: String) -> Int? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map(String.init) ?? ""
        let pieces = token
            .replacingOccurrences(of: ",", with: ":")
            .replacingOccurrences(of: ".", with: ":")
            .split(separator: ":")
            .map(String.init)
        guard pieces.count == 3 || pieces.count == 4 else { return nil }
        let numbers = pieces.compactMap(Int.init)
        guard numbers.count == pieces.count else { return nil }
        let hours: Int
        let minutes: Int
        let seconds: Int
        let fraction: Int
        if numbers.count == 4 {
            hours = numbers[0]
            minutes = numbers[1]
            seconds = numbers[2]
            fraction = numbers[3]
        } else {
            hours = 0
            minutes = numbers[0]
            seconds = numbers[1]
            fraction = numbers[2]
        }
        guard hours >= 0, (0..<60).contains(minutes), (0..<60).contains(seconds) else { return nil }
        let digits = pieces.last?.count ?? 0
        let millis: Int
        switch digits {
        case 1: millis = fraction * 100
        case 2: millis = fraction * 10
        case 3: millis = fraction
        default: return nil
        }
        guard (0..<1000).contains(millis) else { return nil }
        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis
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
