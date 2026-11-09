import Foundation

// ffmpeg's EIA-608 decoder writes ASS positioning and a font wrapper into the
// SRT. Those are not dialogue. Real italics (`<i>`) are left alone.

enum ClosedCaptionText {
    /// Strips `{\an7}` (and the other `{\anN}` positions), `<font …>` /
    /// `</font>`, and turns `\h` into a normal space.
    static func clean(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "\u{feff}", with: "")
        text = replace(text, pattern: "\\{\\\\an\\d+\\}")
        text = replace(text, pattern: "</?font\\b[^>]*>")
        text = text.replacingOccurrences(of: "\\h", with: " ")
        return text
    }

    private static func replace(_ text: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
