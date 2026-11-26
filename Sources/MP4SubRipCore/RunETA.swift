import Foundation

// Time remaining for a running batch (issue #13, ported from mkv-forge #23).
// Rules:
// - Hide below `stablePercent` (5), at 100% and above, when elapsed is 0,
//   after Stop, and when unmeasured (c608) files are at least half of the
//   files still remaining. c608 reports `total == 0` and jumps 0 to 1, so
//   those rows are not extrapolated.
// - A measured in-flight file has `elapsed × (1 − fraction) / fraction` left.
//   Files not started yet use the average duration of files that finished in
//   this run (or that projection, when nothing has finished). Parallel slots
//   share that queued time.
// - Wording matches mkv-forge: nearest second under 60s (a rounded 0 is 1s),
//   nearest minute from 60s, then hours and minutes.
// - `event` publishes through `ProgressThrottle`. Pass a wall-clock `now`.
//   Do not build `now` from elapsed time: a burst that shares one elapsed
//   collapses onto one date and drops every sentence after the first.

/// Time remaining for the batch that is running.
public struct RunETA: Sendable {
    /// The first percent that is large enough to extrapolate. Below this, the caption stays empty.
    public static let stablePercent = 5

    public struct InFlight: Equatable, Sendable {
        /// 0...1 of this file. Unmeasured files stay at 0 until they finish.
        public var fraction: Double
        /// Seconds since this file started, not since the batch started.
        public var elapsed: TimeInterval
        public var unmeasured: Bool

        public init(fraction: Double, elapsed: TimeInterval, unmeasured: Bool) {
            self.fraction = fraction
            self.elapsed = elapsed
            self.unmeasured = unmeasured
        }
    }

    public struct Sample: Equatable, Sendable {
        /// Overall percent, 0...100, from the sum of per-file fractions.
        public var percent: Int
        /// Seconds since this run started. The throttle does not use this as a date.
        public var elapsed: TimeInterval
        public var finishedDurations: [TimeInterval]
        public var inFlight: [InFlight]
        /// Files in this run that have not started.
        public var queuedCount: Int
        /// Slot count. 1 for One at a Time.
        public var concurrency: Int
        public var cancelled: Bool
        /// Remaining files whose progress cannot be measured (c608 still queued or extracting).
        public var unmeasuredRemaining: Int
        /// Files in this run that have not finished.
        public var remainingCount: Int

        public init(
            percent: Int,
            elapsed: TimeInterval,
            finishedDurations: [TimeInterval],
            inFlight: [InFlight],
            queuedCount: Int,
            concurrency: Int,
            cancelled: Bool = false,
            unmeasuredRemaining: Int = 0,
            remainingCount: Int = 1
        ) {
            self.percent = percent
            self.elapsed = elapsed
            self.finishedDurations = finishedDurations
            self.inFlight = inFlight
            self.queuedCount = queuedCount
            self.concurrency = concurrency
            self.cancelled = cancelled
            self.unmeasuredRemaining = unmeasuredRemaining
            self.remainingCount = remainingCount
        }
    }

    public struct Event: Equatable, Sendable {
        public var caption: String

        public init(caption: String) {
            self.caption = caption
        }
    }

    private var throttle = ProgressThrottle()
    private var lastCaption = ""

    public init() {}

    /// Empty when the caption should be hidden.
    public static func caption(_ sample: Sample) -> String {
        guard let seconds = remainingSeconds(sample) else { return "" }
        return sentence(seconds)
    }

    /// A caption change, or nil when this tick should not be published.
    /// `now` is the wall clock. The first visible caption and a hide publish immediately.
    public mutating func event(for sample: Sample, at now: Date = Date()) -> Event? {
        let caption = Self.caption(sample)
        if caption == lastCaption { return nil }
        let force = caption.isEmpty || lastCaption.isEmpty
        guard throttle.shouldPublish(at: now, force: force) else { return nil }
        lastCaption = caption
        return Event(caption: caption)
    }

    static func remainingSeconds(_ sample: Sample) -> TimeInterval? {
        guard !sample.cancelled else { return nil }
        let percent = min(100, max(0, sample.percent))
        guard percent >= stablePercent, percent < 100 else { return nil }
        guard sample.elapsed > 0, sample.queuedCount >= 0, sample.remainingCount > 0 else { return nil }
        // Design Bot: hide when unmeasured files are at least half of what is left.
        if sample.unmeasuredRemaining * 2 >= sample.remainingCount { return nil }

        let slots = max(1, sample.concurrency)
        var projections: [TimeInterval] = []
        var stableRemainings: [TimeInterval] = []
        var unstable: [InFlight] = []
        for file in sample.inFlight {
            let fraction = min(1, max(0, file.fraction))
            let filePercent = Int((fraction * 100).rounded())
            let measured = !file.unmeasured && fraction > 0 && file.elapsed > 0
                && filePercent >= stablePercent && filePercent < 100
            if !measured {
                unstable.append(file)
                continue
            }
            let projected = file.elapsed / fraction
            projections.append(projected)
            stableRemainings.append(max(0, projected - file.elapsed))
        }

        let average: TimeInterval?
        if !sample.finishedDurations.isEmpty {
            let total = sample.finishedDurations.reduce(0, +)
            average = total / Double(sample.finishedDurations.count)
        } else if !projections.isEmpty {
            let total = projections.reduce(0, +)
            average = total / Double(projections.count)
        } else {
            average = nil
        }

        var wave = stableRemainings
        if let average {
            for file in unstable {
                wave.append(max(0, average - max(0, file.elapsed)))
            }
        }
        guard let average else {
            guard let slowest = wave.max(), slowest.isFinite, slowest >= 0 else { return nil }
            return slowest
        }

        let busy = sample.inFlight.count
        let free = max(0, slots - busy)
        let overlap = min(sample.queuedCount, free)
        let later = sample.queuedCount - overlap
        let current = wave.max() ?? 0
        let startedNow = overlap > 0 ? average : 0
        let remaining = max(current, startedNow) + average * Double(later) / Double(slots)
        guard remaining.isFinite, remaining >= 0 else { return nil }
        return remaining
    }

    static func sentence(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "" }
        let rounded = Int(seconds.rounded())
        if rounded < 60 {
            let count = max(1, rounded)
            return count == 1 ? "About 1 second left" : "About \(count) seconds left"
        }
        let minutesTotal = Int((Double(rounded) / 60).rounded())
        if minutesTotal < 60 {
            return minutesTotal == 1 ? "About 1 minute left" : "About \(minutesTotal) minutes left"
        }
        let hours = minutesTotal / 60
        let minutes = minutesTotal % 60
        let hourWord = hours == 1 ? "hour" : "hours"
        if minutes == 0 {
            return "About \(hours) \(hourWord) left"
        }
        let minuteWord = minutes == 1 ? "minute" : "minutes"
        return "About \(hours) \(hourWord) \(minutes) \(minuteWord) left"
    }
}
