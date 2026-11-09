import Foundation

// Compares an `AVAssetReaderOutputCaptionAdaptor` read with the cleaned ffmpeg
// SRT for the same discrete `c608` track. The adaptor is macOS-only. This file
// is the part Linux can test. ffmpeg stays the writer until a Jeannie match
// is accepted: 633 cues, 00:00:01,701 through 00:24:50,269, same text, italics,
// and roll-up shape. No CEA-608 byte decoder lives here.

/// Which path writes the SRT. `RoutingSubtitleReader` switches on this.
enum ClosedCaptionWriter: Equatable, Sendable {
    case ffmpeg
}

/// One cue in the comparison. Times are milliseconds from the start of the file.
struct CaptionCueSnapshot: Equatable, Sendable {
    var startMilliseconds: Int
    var endMilliseconds: Int
    var text: String
    var isRollUp: Bool
}

/// How a roll-up window moved from one cue to the next. Compared after `<i>` tags
/// are removed, so italics and roll-up are separate.
enum ClosedCaptionRollUpStep: Equatable, Sendable {
    /// The next cue repeats the previous lines and adds one.
    case grow
    /// The next cue drops the oldest line and adds one.
    case roll
    /// The next cue repeats the previous lines.
    case hold
    /// Anything else, including a caption that replaces the window.
    case replace
}

/// The known cleaned ffmpeg extract of the Jeannie test file.
enum JeannieClosedCaptionReference {
    static let cueCount = 633
    static let firstStartMilliseconds = 1_701
    static let lastEndMilliseconds = 1_490_269
}

struct ClosedCaptionComparison: Equatable, Sendable {
    var trackID: Int
    var nativeGroupCount: Int
    var nativeCues: [CaptionCueSnapshot]
    var referenceCues: [CaptionCueSnapshot]
    var validationSkipCount: Int
    var validationSkipSamples: [String]
    var textMismatchCount: Int
    var timingMismatchCount: Int
    var italicsMismatchCount: Int
    var rollUpMismatchCount: Int
    var referenceIsJeannieShape: Bool
    var matchesCleanedReference: Bool
    /// Set when the adaptor raised, returned nothing useful, or the reader failed.
    /// A failure is not a match, even if a partial read lined up.
    var failure: String?
}

enum ClosedCaptionSpike {
    /// Shipping writer. Stays `.ffmpeg` until the Jeannie adaptor comparison is
    /// accepted. Do not flip this from a partial or unreviewed log.
    static let writer = ClosedCaptionWriter.ffmpeg

    static func compare(
        trackID: Int,
        nativeGroupCount: Int,
        nativeCues: [CaptionCueSnapshot],
        reference: [SubtitleCue],
        validationSkips: [String]
    ) -> ClosedCaptionComparison {
        let referenceCues = snapshots(from: reference)
        let extraCues = abs(nativeCues.count - referenceCues.count)
        let textMismatch = extraCues + pairedMismatchCount(nativeCues, referenceCues) { native, reference in
            SRTDocument.normalize(native.text) != SRTDocument.normalize(reference.text)
        }
        let timingMismatch = extraCues + pairedMismatchCount(nativeCues, referenceCues) { native, reference in
            native.startMilliseconds != reference.startMilliseconds
                || native.endMilliseconds != reference.endMilliseconds
        }
        let italicsMismatch = extraItalics(nativeCues, referenceCues) + pairedMismatchCount(nativeCues, referenceCues) { native, reference in
            italicMarks(native.text) != italicMarks(reference.text)
        }
        let rollUpMismatch = rollUpMismatchCount(nativeCues, referenceCues)
        let skips = validationSkips.count
        let jeannie = isJeannieShape(referenceCues)
        let matches = skips == 0
            && nativeCues.count > 0
            && nativeCues.count == referenceCues.count
            && textMismatch == 0
            && timingMismatch == 0
            && italicsMismatch == 0
            && rollUpMismatch == 0
        return ClosedCaptionComparison(
            trackID: trackID,
            nativeGroupCount: nativeGroupCount,
            nativeCues: nativeCues,
            referenceCues: referenceCues,
            validationSkipCount: skips,
            validationSkipSamples: skipSamples(validationSkips),
            textMismatchCount: textMismatch,
            timingMismatchCount: timingMismatch,
            italicsMismatchCount: italicsMismatch,
            rollUpMismatchCount: rollUpMismatch,
            referenceIsJeannieShape: jeannie,
            matchesCleanedReference: matches,
            failure: nil
        )
    }

    static func failed(
        trackID: Int,
        reason: String,
        nativeGroupCount: Int = 0,
        nativeCues: [CaptionCueSnapshot] = [],
        reference: [SubtitleCue],
        validationSkips: [String] = []
    ) -> ClosedCaptionComparison {
        var comparison = compare(
            trackID: trackID,
            nativeGroupCount: nativeGroupCount,
            nativeCues: nativeCues,
            reference: reference,
            validationSkips: validationSkips
        )
        comparison.failure = oneLine(reason, limit: 300)
        comparison.matchesCleanedReference = false
        return comparison
    }

    /// Summary, then any validation-skip names, then the first five native groups.
    /// The summary has counts and times. The group lines carry the caption text
    /// the spike has to record.
    static func logLines(_ comparison: ClosedCaptionComparison) -> [String] {
        var lines = ["Caption adaptor track \(comparison.trackID): \(summary(comparison))"]
        if !comparison.validationSkipSamples.isEmpty {
            let names = comparison.validationSkipSamples.joined(separator: ", ")
            lines.append(
                "Caption adaptor track \(comparison.trackID): validation skips \(comparison.validationSkipCount) (\(names))"
            )
        }
        for (offset, cue) in comparison.nativeCues.prefix(5).enumerated() {
            let roll = cue.isRollUp ? "yes" : "no"
            lines.append(
                "Caption adaptor track \(comparison.trackID) group \(offset + 1) \(SRTDocument.stamp(cue.startMilliseconds)) --> \(SRTDocument.stamp(cue.endMilliseconds)) roll-up \(roll): \(previewText(cue.text))"
            )
        }
        return lines
    }

    static func rollUpSteps(_ cues: [CaptionCueSnapshot]) -> [ClosedCaptionRollUpStep] {
        guard cues.count >= 2 else { return [] }
        return (1..<cues.count).map { index in
            rollUpStep(from: plainLines(cues[index - 1].text), to: plainLines(cues[index].text))
        }
    }

    static func isJeannieShape(_ cues: [CaptionCueSnapshot]) -> Bool {
        guard cues.count == JeannieClosedCaptionReference.cueCount,
              let first = cues.first,
              let last = cues.last else {
            return false
        }
        return first.startMilliseconds == JeannieClosedCaptionReference.firstStartMilliseconds
            && last.endMilliseconds == JeannieClosedCaptionReference.lastEndMilliseconds
    }

    private static func snapshots(from cues: [SubtitleCue]) -> [CaptionCueSnapshot] {
        cues.map {
            CaptionCueSnapshot(
                startMilliseconds: $0.startMilliseconds,
                endMilliseconds: $0.endMilliseconds,
                text: $0.text,
                isRollUp: false
            )
        }
    }

    private static func pairedMismatchCount(
        _ native: [CaptionCueSnapshot],
        _ reference: [CaptionCueSnapshot],
        differs: (CaptionCueSnapshot, CaptionCueSnapshot) -> Bool
    ) -> Int {
        let pairs = min(native.count, reference.count)
        var count = 0
        for index in 0..<pairs where differs(native[index], reference[index]) {
            count += 1
        }
        return count
    }

    /// Extra cues are an italics miss only when they actually carry `<i>`.
    private static func extraItalics(
        _ native: [CaptionCueSnapshot],
        _ reference: [CaptionCueSnapshot]
    ) -> Int {
        let pairs = min(native.count, reference.count)
        let extras = Array(native.dropFirst(pairs)) + Array(reference.dropFirst(pairs))
        return extras.reduce(0) { count, cue in
            italicMarks(cue.text).isEmpty ? count : count + 1
        }
    }

    private static func rollUpMismatchCount(
        _ native: [CaptionCueSnapshot],
        _ reference: [CaptionCueSnapshot]
    ) -> Int {
        let nativeSteps = rollUpSteps(native)
        let referenceSteps = rollUpSteps(reference)
        let pairs = min(nativeSteps.count, referenceSteps.count)
        var count = abs(nativeSteps.count - referenceSteps.count)
        for index in 0..<pairs where nativeSteps[index] != referenceSteps[index] {
            count += 1
        }
        return count
    }

    private static func rollUpStep(from previous: [String], to current: [String]) -> ClosedCaptionRollUpStep {
        if current == previous { return .hold }
        if current.count == previous.count + 1, Array(current.dropLast()) == previous { return .grow }
        if previous.count >= 2,
           current.count == previous.count,
           Array(current.dropLast()) == Array(previous.dropFirst()) {
            return .roll
        }
        return .replace
    }

    /// Lines used for roll-up, with italic tags taken off so a style change is
    /// not mistaken for a new line.
    static func plainLines(_ text: String) -> [String] {
        var stripped = text
        stripped = stripped.replacingOccurrences(of: "<i>", with: "", options: [.caseInsensitive])
        stripped = stripped.replacingOccurrences(of: "</i>", with: "", options: [.caseInsensitive])
        let normalized = SRTDocument.normalize(stripped)
        if normalized.isEmpty { return [] }
        return normalized.components(separatedBy: "\n")
    }

    /// `<i>` and `</i>` only, in order, so a wording change is not an italics miss.
    static func italicMarks(_ text: String) -> String {
        let lower = text.lowercased()
        var result = ""
        var index = lower.startIndex
        while index < lower.endIndex {
            if lower[index...].hasPrefix("</i>") {
                result += "</i>"
                index = lower.index(index, offsetBy: 4)
            } else if lower[index...].hasPrefix("<i>") {
                result += "<i>"
                index = lower.index(index, offsetBy: 3)
            } else {
                index = lower.index(after: index)
            }
        }
        return result
    }

    private static func summary(_ comparison: ClosedCaptionComparison) -> String {
        let shipping: String
        switch writer {
        case .ffmpeg:
            shipping = "ffmpeg"
        }
        var parts = [
            "groups \(comparison.nativeGroupCount)",
            "native cues \(comparison.nativeCues.count)",
            "ffmpeg cues \(comparison.referenceCues.count)",
            "validation skips \(comparison.validationSkipCount)",
            "text mismatches \(comparison.textMismatchCount)",
            "timing mismatches \(comparison.timingMismatchCount)",
            "italics mismatches \(comparison.italicsMismatchCount)",
            "roll-up mismatches \(comparison.rollUpMismatchCount)",
            referenceSpan(comparison.referenceCues),
            "Jeannie shape \(comparison.referenceIsJeannieShape ? "yes" : "no")",
            "match \(comparison.matchesCleanedReference ? "yes" : "no")",
            "shipping \(shipping)"
        ]
        if let failure = comparison.failure, !failure.isEmpty {
            parts.insert("failed (\(failure))", at: 0)
        }
        var line = parts.joined(separator: ", ")
        line += ". " + adoptionNote(comparison)
        return line
    }

    private static func adoptionNote(_ comparison: ClosedCaptionComparison) -> String {
        if comparison.matchesCleanedReference && comparison.referenceIsJeannieShape {
            return "native matches the cleaned Jeannie SRT; shipping stays ffmpeg until that is accepted"
        }
        if comparison.matchesCleanedReference {
            return "native matches this file's cleaned ffmpeg SRT; shipping stays ffmpeg"
        }
        return "keep ffmpeg"
    }

    private static func referenceSpan(_ cues: [CaptionCueSnapshot]) -> String {
        guard let first = cues.first, let last = cues.last else { return "ffmpeg none" }
        return "ffmpeg first \(SRTDocument.stamp(first.startMilliseconds)) last \(SRTDocument.stamp(last.endMilliseconds))"
    }

    private static func skipSamples(_ elements: [String]) -> [String] {
        var seen: [String] = []
        for element in elements {
            let cleaned = oneLine(element, limit: 80)
            if cleaned.isEmpty || seen.contains(cleaned) { continue }
            seen.append(cleaned)
            if seen.count == 8 { break }
        }
        return seen
    }

    private static func previewText(_ text: String) -> String {
        let flat = oneLine(text.replacingOccurrences(of: "\n", with: " | "), limit: 80)
        return flat
    }

    private static func oneLine(_ text: String, limit: Int) -> String {
        var flat = text.replacingOccurrences(of: "\r\n", with: " ")
        flat = flat.replacingOccurrences(of: "\n", with: " ")
        flat = flat.replacingOccurrences(of: "\r", with: " ")
        flat = flat.trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.count <= limit { return flat }
        return String(flat.prefix(limit))
    }
}
