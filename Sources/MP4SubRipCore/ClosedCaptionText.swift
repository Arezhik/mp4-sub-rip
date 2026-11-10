import Foundation

// ffmpeg's EIA-608 decoder writes ASS positioning and a font wrapper into the
// SRT. Those are not dialogue. A later `{\anN}` in the same cue is another
// caption packed into it, so that marker becomes a line break. Real italics
// (`<i>`) are left alone. Glue is not guessed from punctuation.

enum ClosedCaptionText {
    /// Strips the first `{\anN}` in each cue. Any later one becomes a line
    /// break. `<font>` tags are removed and `\h` becomes a space.
    static func clean(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "\u{feff}", with: "")
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        let blocks = text.components(separatedBy: "\n\n").map { breakLaterPositionMarkers($0) }
        var cleaned = blocks.joined(separator: "\n\n")
        cleaned = replace(cleaned, pattern: "</?font\\b[^>]*>")
        cleaned = cleaned.replacingOccurrences(of: "\\h", with: " ")
        return cleaned
    }

    /// The first `{\anN}` in a cue is positioning and is removed, as before.
    /// Each later one is the boundary ffmpeg left between two captions.
    private static func breakLaterPositionMarkers(_ block: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\{\\\\an\\d+\\}", options: [.caseInsensitive]) else {
            return block
        }
        let full = NSRange(block.startIndex..., in: block)
        let matches = regex.matches(in: block, range: full)
        guard !matches.isEmpty else { return block }
        var result = ""
        var cursor = block.startIndex
        for (index, match) in matches.enumerated() {
            guard let range = Range(match.range, in: block) else { continue }
            result.append(contentsOf: block[cursor..<range.lowerBound])
            if index > 0 { result.append("\n") }
            cursor = range.upperBound
        }
        result.append(contentsOf: block[cursor...])
        return result
    }

    private static func replace(_ text: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
