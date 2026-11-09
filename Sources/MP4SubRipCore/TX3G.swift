import Foundation

// tx3g sample layout, from the QuickTime File Format ("Subtitle sample data")
// and 3GPP TS 26.245:
//   UInt16 big-endian byte length of the text
//   that many bytes of UTF-8, or UTF-16 if the text starts with a BOM
//   optional modifier atoms (`styl`, `frcd`, `tbox`, ...)
// An empty text sample is a gap between cues, not a blank subtitle.
// Style records: face flags bit 0 bold, bit 1 italic, bit 2 underline.
// `endChar` is the first character the style does not apply to.

/// Display flags in a tx3g sample description (QuickTime subtitle sample description).
enum TX3GDisplayFlag {
    /// At least one sample contains a `frcd` atom.
    static let someSamplesForced: UInt32 = 0x4000_0000
    /// Every sample is forced, whether or not it has a `frcd` atom.
    /// QuickTime requires `someSamplesForced` to be set as well (0xC0000000).
    static let allSamplesForced: UInt32 = 0x8000_0000
}

/// One parsed tx3g sample, before it is paired with the next sample's time.
struct TX3GTimedSample: Equatable, Sendable {
    var startMilliseconds: Int
    /// Nil when the sample duration is missing or zero. The assembler then uses
    /// the next sample's start, which is how some files encode cue length.
    var endMilliseconds: Int?
    /// Nil for a gap (empty text) .
    var text: String?
    var isForced: Bool
}

enum TX3GSample {
    enum Parse: Equatable {
        case gap
        case malformed
        case cue(text: String, isForced: Bool)
    }

    static func parse(_ data: Data, defaultFaceStyle: UInt8 = 0) -> Parse {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return .malformed }
        let length = Int(TX3GBytes.readU16(bytes, 0))
        guard bytes.count >= 2 + length else { return .malformed }
        let body = Array(bytes[2..<(2 + length)])
        let modifiers: TX3GModifiers
        switch TX3GModifiers.parse(Array(bytes[(2 + length)...])) {
        case let .success(value):
            modifiers = value
        case .failure:
            return .malformed
        }
        guard length > 0 else { return .gap }
        guard let decoded = decodeText(body) else { return .malformed }
        let styled = StyleMarkup.apply(
            decoded,
            spans: modifiers.spans,
            defaultFlags: defaultFaceStyle
        )
        if styled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .gap }
        return .cue(text: styled, isForced: modifiers.forced)
    }

    /// UTF-16 when a BOM is present (FE FF or FF FE), otherwise UTF-8.
    /// A UTF-8 BOM is stripped and is not part of the text. Invalid bytes fail
    /// the sample instead of inserting replacement characters.
    static func decodeText(_ body: [UInt8]) -> String? {
        if body.count >= 2, body[0] == 0xFE, body[1] == 0xFF {
            return String(data: Data(body), encoding: .utf16)
        }
        if body.count >= 2, body[0] == 0xFF, body[1] == 0xFE {
            return String(data: Data(body), encoding: .utf16)
        }
        var utf8 = body
        if utf8.count >= 3, utf8[0] == 0xEF, utf8[1] == 0xBB, utf8[2] == 0xBF {
            utf8.removeFirst(3)
        }
        return String(bytes: utf8, encoding: .utf8)
    }
}

struct StyleSpan: Equatable {
    var start: Int
    var end: Int
    var flags: UInt8
}

private struct TX3GModifiers {
    var forced = false
    var spans: [StyleSpan] = []

    static func parse(_ bytes: [UInt8]) -> Result<TX3GModifiers, TX3GParseFailure> {
        var offset = 0
        var modifiers = TX3GModifiers()
        while offset < bytes.count {
            guard offset + 8 <= bytes.count else { return .failure(TX3GParseFailure()) }
            let size = Int(TX3GBytes.readU32(bytes, offset))
            guard size >= 8, offset + size <= bytes.count else { return .failure(TX3GParseFailure()) }
            let type = TX3GBytes.fourCC(bytes, offset + 4)
            let payload = Array(bytes[(offset + 8)..<(offset + size)])
            if type == "frcd" {
                modifiers.forced = true
            } else if type == "styl" {
                switch parseStyles(payload) {
                case let .success(spans):
                    modifiers.spans.append(contentsOf: spans)
                case .failure:
                    return .failure(TX3GParseFailure())
                }
            }
            offset += size
        }
        return .success(modifiers)
    }

    /// `styl` payload: UInt16 count, then that many 12-byte style records.
    private static func parseStyles(_ payload: [UInt8]) -> Result<[StyleSpan], TX3GParseFailure> {
        guard payload.count >= 2 else { return .failure(TX3GParseFailure()) }
        let count = Int(TX3GBytes.readU16(payload, 0))
        var offset = 2
        var spans: [StyleSpan] = []
        for _ in 0..<count {
            guard offset + 12 <= payload.count else { return .failure(TX3GParseFailure()) }
            let start = Int(TX3GBytes.readU16(payload, offset))
            let end = Int(TX3GBytes.readU16(payload, offset + 2))
            let face = payload[offset + 6]
            if end > start {
                spans.append(StyleSpan(start: start, end: end, flags: face))
            }
            offset += 12
        }
        return .success(spans)
    }
}

private struct TX3GParseFailure: Error {}

enum TX3GBytes {
    static func readU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    static func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    static func fourCC(_ bytes: [UInt8], _ offset: Int) -> String {
        String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? ""
    }
}

/// Maps tx3g face flags onto SRT `<b>`, `<i>`, and `<u>`.
/// Records replace the default style for their range (3GPP: they don't overlap;
/// if they do, the later record wins). Characters outside every record keep the
/// default face from the sample description. Plain cues are not escaped, so
/// "5 < 10" stays readable in players that don't treat SRT as HTML.
enum StyleMarkup {
    static func apply(_ text: String, spans: [StyleSpan], defaultFlags: UInt8) -> String {
        let scalars = Array(text.unicodeScalars)
        if scalars.isEmpty { return "" }
        let styled = defaultFlags != 0 || spans.contains { $0.flags != 0 }
        if !styled { return text }

        func flags(at index: Int) -> UInt8 {
            var chosen: UInt8?
            for span in spans where index >= span.start && index < span.end {
                chosen = span.flags
            }
            return chosen ?? defaultFlags
        }

        var result = ""
        var index = 0
        while index < scalars.count {
            let flag = flags(at: index)
            var run = String.UnicodeScalarView()
            run.append(scalars[index])
            index += 1
            while index < scalars.count && flags(at: index) == flag {
                run.append(scalars[index])
                index += 1
            }
            result += wrap(escape(String(run)), flags: flag)
        }
        return result
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Underline inside italic inside bold, so the tags nest cleanly.
    private static func wrap(_ text: String, flags: UInt8) -> String {
        var text = text
        if flags & 0x04 != 0 { text = "<u>\(text)</u>" }
        if flags & 0x02 != 0 { text = "<i>\(text)</i>" }
        if flags & 0x01 != 0 { text = "<b>\(text)</b>" }
        return text
    }
}

/// The tx3g sample description, when we can see its bytes.
/// Layout after the `tx3g` fourcc: 6 reserved bytes, a 2-byte data reference,
/// then display flags. The default face-style byte follows the text box.
enum TX3GSampleEntry {
    struct Header: Equatable {
        var displayFlags: UInt32
        var defaultFaceStyle: UInt8
    }

    static func header(in data: Data) -> Header? {
        let bytes = [UInt8](data)
        guard let type = indexOfTX3G(bytes) else { return nil }
        // type + reserved(6) + data reference(2) = 12, then 4 flag bytes.
        guard bytes.count >= type + 16 else { return nil }
        let flags = TX3GBytes.readU32(bytes, type + 12)
        // After the 4 flag bytes: justification (2), background (4), text box (8),
        // startChar (2), endChar (2), font ID (2), then the face-style byte.
        // That is 24 bytes after the flags, at type + 12 + 4 + 20 = type + 36.
        let face: UInt8 = bytes.count >= type + 37 ? bytes[type + 36] : 0
        return Header(displayFlags: flags, defaultFaceStyle: face)
    }

    /// Walks a format-description extension tree for a buffer that contains `tx3g`.
    static func findSampleEntry(in value: Any) -> Data? {
        if let data = value as? Data {
            return indexOfTX3G([UInt8](data)) != nil ? data : nil
        }
        if let data = value as? NSData {
            let copy = data as Data
            return indexOfTX3G([UInt8](copy)) != nil ? copy : nil
        }
        if let dictionary = value as? [String: Any] {
            for child in dictionary.values {
                if let found = findSampleEntry(in: child) { return found }
            }
            return nil
        }
        if let dictionary = value as? NSDictionary {
            for key in dictionary.allKeys {
                if let child = dictionary.object(forKey: key), let found = findSampleEntry(in: child) {
                    return found
                }
            }
            return nil
        }
        if let list = value as? [Any] {
            for child in list {
                if let found = findSampleEntry(in: child) { return found }
            }
        }
        return nil
    }
}

private func indexOfTX3G(_ bytes: [UInt8]) -> Int? {
    let marker: [UInt8] = [0x74, 0x78, 0x33, 0x67]
    guard bytes.count >= 4 else { return nil }
    for index in 0...(bytes.count - 4) {
        if Array(bytes[index..<(index + 4)]) == marker { return index }
    }
    return nil
}

/// Builds cues from samples in presentation order.
/// A sample with text and no positive duration ends when the next sample starts.
/// The last such sample is given one second so it is still visible.
struct CueStreamAssembler {
    private var pending: TX3GTimedSample?

    mutating func add(_ sample: TX3GTimedSample) -> SubtitleCue? {
        let produced = pending.flatMap { Self.makeCue($0, nextStart: sample.startMilliseconds) }
        pending = sample
        return produced
    }

    mutating func finish() -> SubtitleCue? {
        guard let pending else { return nil }
        self.pending = nil
        return Self.makeCue(pending, nextStart: nil)
    }

    static func cues(from samples: [TX3GTimedSample]) -> [SubtitleCue] {
        let ordered = samples.sorted { $0.startMilliseconds < $1.startMilliseconds }
        var assembler = CueStreamAssembler()
        var cues: [SubtitleCue] = []
        for sample in ordered {
            if let cue = assembler.add(sample) { cues.append(cue) }
        }
        if let cue = assembler.finish() { cues.append(cue) }
        return cues
    }

    private static func makeCue(_ sample: TX3GTimedSample, nextStart: Int?) -> SubtitleCue? {
        guard let text = sample.text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let start = max(0, sample.startMilliseconds)
        let end: Int
        if let known = sample.endMilliseconds, known > start {
            end = known
        } else if let nextStart, nextStart > start {
            end = nextStart
        } else {
            end = start + 1000
        }
        return SubtitleCue(
            startMilliseconds: start,
            endMilliseconds: end,
            text: text,
            isForced: sample.isForced
        )
    }
}

/// Media time as whole milliseconds, rounded to nearest, clamped at zero.
/// Integer math avoids the drift of `CMTime.seconds` on long files.
enum MediaTime {
    static func milliseconds(value: Int64, timescale: Int32) -> Int {
        guard timescale > 0, value > 0 else { return 0 }
        let scale = Int64(timescale)
        let (product, overflow) = value.multipliedReportingOverflow(by: 1000)
        let rounded: Int64
        if overflow {
            let whole = value / scale
            let (wholeMs, wholeOverflow) = whole.multipliedReportingOverflow(by: 1000)
            if wholeOverflow { return Int.max }
            let remainder = value % scale
            let extra = (remainder * 1000 + scale / 2) / scale
            let (sum, sumOverflow) = wholeMs.addingReportingOverflow(extra)
            rounded = sumOverflow ? Int64.max : sum
        } else {
            rounded = (product + scale / 2) / scale
        }
        if rounded > Int64(Int.max) { return Int.max }
        return Int(rounded)
    }
}
