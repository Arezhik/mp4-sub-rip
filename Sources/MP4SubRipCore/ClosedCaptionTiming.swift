import Foundation

// ffmpeg's caption timing can put two captions on the same range, and it can
// flush the last caption with a made-up duration under a second. This flattens
// the ranges and lengthens only that short ending. tx3g never comes through here.

enum ClosedCaptionTiming {
    /// Flattens overlaps, then lengthens a last cue shorter than one second.
    ///
    /// Overlaps are split at every cue edge. Each slice shows the text of every
    /// caption active there, in the order the cues were given, and neighboring
    /// slices with the same text become one cue.
    ///
    /// A last cue under 1,000 ms grows to `max(1,500 ms, 60 ms × visible
    /// characters)`, and stops at 6 seconds. When `movieDurationMilliseconds`
    /// is past the cue start, it also stops at the end of the movie. Pass nil
    /// when the length is unknown. The extract path passes nil: the movie
    /// length is known only on the reader, and threading it through is more
    /// than a one-line change.
    static func tidy(
        _ cues: [SubtitleCue],
        movieDurationMilliseconds: Int? = nil
    ) throws -> [SubtitleCue] {
        try Task.checkCancellation()
        let flattened = try flattenOverlaps(cues)
        return extendShortEnding(flattened, movieDurationMilliseconds: movieDurationMilliseconds)
    }

    private static func flattenOverlaps(_ cues: [SubtitleCue]) throws -> [SubtitleCue] {
        if cues.count < 2 { return cues }
        let overlapping = try overlaps(cues)
        if !overlapping { return cues }

        var points: Set<Int> = []
        for cue in cues {
            try Task.checkCancellation()
            points.insert(cue.startMilliseconds)
            points.insert(cue.endMilliseconds)
        }
        let bounds = points.sorted()
        var slices: [SubtitleCue] = []
        guard bounds.count >= 2 else { return cues }
        for index in 0..<(bounds.count - 1) {
            try Task.checkCancellation()
            let start = bounds[index]
            let end = bounds[index + 1]
            if end <= start { continue }
            let active = cues.filter { cue in
                cue.endMilliseconds > cue.startMilliseconds
                    && cue.startMilliseconds <= start
                    && cue.endMilliseconds >= end
            }
            if active.isEmpty { continue }
            let text = active.map(\.text).joined(separator: "\n")
            let forced = active.allSatisfy(\.isForced)
            if var last = slices.last,
               last.endMilliseconds == start,
               last.text == text,
               last.isForced == forced {
                last.endMilliseconds = end
                slices[slices.count - 1] = last
            } else {
                slices.append(SubtitleCue(
                    startMilliseconds: start,
                    endMilliseconds: end,
                    text: text,
                    isForced: forced
                ))
            }
        }
        return slices
    }

    /// True when two positive-length cues share an open moment. A cue that
    /// merely ends when the next one starts does not overlap.
    private static func overlaps(_ cues: [SubtitleCue]) throws -> Bool {
        let ordered = cues.enumerated().sorted { lhs, rhs in
            if lhs.element.startMilliseconds != rhs.element.startMilliseconds {
                return lhs.element.startMilliseconds < rhs.element.startMilliseconds
            }
            return lhs.offset < rhs.offset
        }
        var maxEnd = Int.min
        for item in ordered {
            try Task.checkCancellation()
            let cue = item.element
            guard cue.endMilliseconds > cue.startMilliseconds else { continue }
            if cue.startMilliseconds < maxEnd { return true }
            if cue.endMilliseconds > maxEnd { maxEnd = cue.endMilliseconds }
        }
        return false
    }

    private static func extendShortEnding(
        _ cues: [SubtitleCue],
        movieDurationMilliseconds: Int?
    ) -> [SubtitleCue] {
        guard var last = cues.last else { return cues }
        let duration = last.endMilliseconds - last.startMilliseconds
        guard duration < 1_000 else { return cues }
        var extended = max(1_500, 60 * visibleCharacterCount(last.text))
        if extended > 6_000 { extended = 6_000 }
        if let movie = movieDurationMilliseconds, movie > last.startMilliseconds {
            let room = movie - last.startMilliseconds
            if extended > room { extended = room }
        }
        guard extended > duration else { return cues }
        last.endMilliseconds = last.startMilliseconds + extended
        var updated = cues
        updated[updated.count - 1] = last
        return updated
    }

    /// Characters on screen. Markup and line breaks add no time.
    private static func visibleCharacterCount(_ text: String) -> Int {
        var count = 0
        var inTag = false
        for character in text {
            if character == "<" {
                inTag = true
                continue
            }
            if inTag {
                if character == ">" { inTag = false }
                continue
            }
            if character.isNewline { continue }
            count += 1
        }
        return count
    }
}
