import Foundation

// What the bottom bar, the window subtitle, and the Dock badge show for one
// run (issues #13 and #14). Rows that settled at probe time (no subtitles,
// image-only) are not in the run. Stop is not a finish: the bar goes idle
// and the summary says how far the run got. Adding files or Clear Processed
// drops a finished or stopped summary; that decision lives in the app.

/// One file that Extract started, or that joined the run while it was going.
public struct RunRow: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable {
        case waiting
        /// `fraction` is 0...1. A c608 row reports `total == 0` and stays at 0 until it finishes.
        case extracting(fraction: Double)
        case finished(Finish)
    }

    public enum Finish: Equatable, Sendable {
        /// `saved` was written this run. `existed` was already on disk (Skip).
        case succeeded(saved: [String], existed: [String])
        case failed
        case noSubtitles
        case imageOnly
        case skipped
    }

    public var id: UUID
    public var state: State
    /// True when this file cannot report a fraction (discrete c608, or `total == 0`).
    public var unmeasured: Bool

    public init(id: UUID, state: State, unmeasured: Bool) {
        self.id = id
        self.state = state
        self.unmeasured = unmeasured
    }

    public var isFinished: Bool {
        if case .finished = state { return true }
        return false
    }
}

/// Builds a run row from the queue. Probing rows are not part of a run.
public enum RunRows {
    public static func isUnmeasured(tracks: [SubtitleTrack]) -> Bool {
        let extractable = tracks.filter(\.isExtractable)
        guard !extractable.isEmpty else { return false }
        return extractable.allSatisfy { $0.codec == FFmpegClosedCaptions.codec }
    }

    public static func make(id: UUID, status: JobStatus, tracks: [SubtitleTrack]) -> RunRow? {
        switch status {
        case .probing:
            return nil
        case .waiting:
            return RunRow(id: id, state: .waiting, unmeasured: isUnmeasured(tracks: tracks))
        case let .working(completed, total):
            let fraction = total > 0 ? min(1, max(0, Double(completed) / Double(total))) : 0
            return RunRow(id: id, state: .extracting(fraction: fraction), unmeasured: total <= 0)
        case let .done(written, skipped):
            return RunRow(
                id: id,
                state: .finished(.succeeded(saved: written, existed: skipped)),
                unmeasured: false
            )
        case let .skippedExists(paths):
            return RunRow(
                id: id,
                state: .finished(.succeeded(saved: [], existed: paths)),
                unmeasured: false
            )
        case .failed:
            return RunRow(id: id, state: .finished(.failed), unmeasured: false)
        case .noSubtitles:
            return RunRow(id: id, state: .finished(.noSubtitles), unmeasured: false)
        case .imageSubsOnly:
            return RunRow(id: id, state: .finished(.imageOnly), unmeasured: false)
        case .skipped:
            return RunRow(id: id, state: .finished(.skipped), unmeasured: false)
        case .canceled:
            return RunRow(id: id, state: .waiting, unmeasured: isUnmeasured(tracks: tracks))
        }
    }

    public static func make(_ item: QueueItem) -> RunRow? {
        make(id: item.id, status: item.status, tracks: item.tracks)
    }
}

/// Idle, running, finished, or stopped. The app picks this. The numbers come from the rows.
public enum RunPhase: Equatable, Sendable {
    case idle
    case running
    case finished
    case stopped
}

/// The bottom bar, subtitle, and Dock badge for the current phase.
public struct RunPresentation: Equatable, Sendable {
    public var phase: RunPhase
    /// Nil while idle, so the queue's own summary (`7 files · 9 text tracks`) stays.
    public var leadingSummary: String?
    /// No-subtitles and image-only counts. Empty when there is nothing extra.
    public var leadingHelp: String
    public var toolbarSubtitle: String
    public var showsColumn: Bool
    /// 0...1. Finished is 1. `(completed + in-flight fractions) / files in the run`.
    public var fraction: Double
    /// Running: time remaining, or empty when that estimate is hidden.
    /// Finished: `N .srt saved`, with existed files called out.
    public var caption: String
    /// VoiceOver value for the bar. The count, plus the ETA when the caption is visible.
    public var accessibilityValue: String
    public var showsFinder: Bool
    /// Saved outputs plus skipped-existing outputs, in row order.
    public var outputPaths: [String]
    /// Remaining files while running. Nil when idle, finished, stopped, or nothing is left.
    public var dockBadge: String?
    public var total: Int
    public var completed: Int
    public var extracting: Int
    public var remaining: Int
    public var succeeded: Int
    public var failed: Int
    public var savedCount: Int
    public var existedCount: Int

    public init(
        phase: RunPhase,
        leadingSummary: String?,
        leadingHelp: String,
        toolbarSubtitle: String,
        showsColumn: Bool,
        fraction: Double,
        caption: String,
        accessibilityValue: String,
        showsFinder: Bool,
        outputPaths: [String],
        dockBadge: String?,
        total: Int,
        completed: Int,
        extracting: Int,
        remaining: Int,
        succeeded: Int,
        failed: Int,
        savedCount: Int,
        existedCount: Int
    ) {
        self.phase = phase
        self.leadingSummary = leadingSummary
        self.leadingHelp = leadingHelp
        self.toolbarSubtitle = toolbarSubtitle
        self.showsColumn = showsColumn
        self.fraction = fraction
        self.caption = caption
        self.accessibilityValue = accessibilityValue
        self.showsFinder = showsFinder
        self.outputPaths = outputPaths
        self.dockBadge = dockBadge
        self.total = total
        self.completed = completed
        self.extracting = extracting
        self.remaining = remaining
        self.succeeded = succeeded
        self.failed = failed
        self.savedCount = savedCount
        self.existedCount = existedCount
    }

    public static let idle = RunPresentation(
        phase: .idle,
        leadingSummary: nil,
        leadingHelp: "",
        toolbarSubtitle: "",
        showsColumn: false,
        fraction: 0,
        caption: "",
        accessibilityValue: "",
        showsFinder: false,
        outputPaths: [],
        dockBadge: nil,
        total: 0,
        completed: 0,
        extracting: 0,
        remaining: 0,
        succeeded: 0,
        failed: 0,
        savedCount: 0,
        existedCount: 0
    )
}

public enum RunProgress {
    /// `etaCaption` is the running estimate. Finished text replaces it.
    public static func presentation(phase: RunPhase, rows: [RunRow], etaCaption: String = "") -> RunPresentation {
        guard phase != .idle, !rows.isEmpty else { return .idle }
        let counts = tally(rows)
        switch phase {
        case .idle:
            return .idle
        case .running:
            return running(counts, etaCaption: etaCaption)
        case .finished:
            return finished(counts)
        case .stopped:
            return stopped(counts)
        }
    }

    /// The sample `RunETA` turns into a caption. `now` is the wall clock.
    public static func etaSample(
        rows: [RunRow],
        runElapsed: TimeInterval,
        finishedDurations: [TimeInterval],
        concurrency: Int,
        cancelled: Bool = false,
        now: Date = Date(),
        startedAt: [UUID: Date] = [:]
    ) -> RunETA.Sample {
        var inFlight: [RunETA.InFlight] = []
        var queued = 0
        var unmeasuredRemaining = 0
        var remaining = 0
        for row in rows {
            switch row.state {
            case .waiting:
                queued += 1
                remaining += 1
                if row.unmeasured { unmeasuredRemaining += 1 }
            case let .extracting(fraction):
                remaining += 1
                if row.unmeasured { unmeasuredRemaining += 1 }
                let elapsed = startedAt[row.id].map { max(0, now.timeIntervalSince($0)) } ?? 0
                inFlight.append(RunETA.InFlight(fraction: fraction, elapsed: elapsed, unmeasured: row.unmeasured))
            case .finished:
                break
            }
        }
        let fraction = overallFraction(rows)
        let percent = Int((fraction * 100).rounded())
        return RunETA.Sample(
            percent: percent,
            elapsed: runElapsed,
            finishedDurations: finishedDurations,
            inFlight: inFlight,
            queuedCount: queued,
            concurrency: concurrency,
            cancelled: cancelled,
            unmeasuredRemaining: unmeasuredRemaining,
            remainingCount: remaining
        )
    }

    public static func overallFraction(_ rows: [RunRow]) -> Double {
        guard !rows.isEmpty else { return 0 }
        let completed = rows.filter(\.isFinished).count
        let partial = rows.reduce(0.0) { sum, row in
            guard case let .extracting(fraction) = row.state else { return sum }
            return sum + min(1, max(0, fraction))
        }
        return (Double(completed) + partial) / Double(rows.count)
    }

    public static func savedCaption(saved: Int, existed: Int) -> String {
        if saved > 0 && existed > 0 { return "\(saved) .srt saved · \(existed) existed" }
        if saved > 0 { return "\(saved) .srt saved" }
        if existed > 0 { return "\(existed) already existed" }
        return ""
    }

    private struct Counts {
        var total: Int
        var completed: Int
        var extracting: Int
        var remaining: Int
        var succeeded: Int
        var failed: Int
        var noSubtitles: Int
        var imageOnly: Int
        var skipped: Int
        var saved: Int
        var existed: Int
        var paths: [String]
        var fraction: Double
    }

    private static func tally(_ rows: [RunRow]) -> Counts {
        var saved = 0
        var existed = 0
        var paths: [String] = []
        var succeeded = 0
        var failed = 0
        var noSubtitles = 0
        var imageOnly = 0
        var skipped = 0
        var extracting = 0
        for row in rows {
            switch row.state {
            case .waiting:
                break
            case .extracting:
                extracting += 1
            case let .finished(finish):
                switch finish {
                case let .succeeded(written, already):
                    succeeded += 1
                    saved += written.count
                    existed += already.count
                    // Queue order: this file's new subtitles, then the ones it skipped.
                    paths.append(contentsOf: written)
                    paths.append(contentsOf: already)
                case .failed:
                    failed += 1
                case .noSubtitles:
                    noSubtitles += 1
                case .imageOnly:
                    imageOnly += 1
                case .skipped:
                    skipped += 1
                }
            }
        }
        let completed = rows.filter(\.isFinished).count
        return Counts(
            total: rows.count,
            completed: completed,
            extracting: extracting,
            remaining: rows.count - completed,
            succeeded: succeeded,
            failed: failed,
            noSubtitles: noSubtitles,
            imageOnly: imageOnly,
            skipped: skipped,
            saved: saved,
            existed: existed,
            paths: paths,
            fraction: overallFraction(rows)
        )
    }

    private static func running(_ counts: Counts, etaCaption: String) -> RunPresentation {
        let summary = "\(counts.completed) of \(counts.total) complete · \(counts.extracting) extracting"
        let subtitle = "Extracting · \(counts.completed) of \(counts.total) complete"
        let value = etaCaption.isEmpty ? summaryCount(counts) : "\(summaryCount(counts)), \(etaCaption)"
        let badge = counts.remaining > 0 ? String(counts.remaining) : nil
        return make(
            counts,
            phase: .running,
            leading: summary,
            help: "",
            subtitle: subtitle,
            showsColumn: true,
            fraction: counts.fraction,
            caption: etaCaption,
            value: value,
            showsFinder: false,
            badge: badge
        )
    }

    private static func finished(_ counts: Counts) -> RunPresentation {
        let summary = finishedSummary(counts)
        let caption = savedCaption(saved: counts.saved, existed: counts.existed)
        let subtitle = "Finished · \(counts.succeeded) of \(counts.total) succeeded"
        return make(
            counts,
            phase: .finished,
            leading: summary.text,
            help: summary.help,
            subtitle: subtitle,
            showsColumn: true,
            fraction: 1,
            caption: caption,
            value: caption.isEmpty ? subtitle : caption,
            showsFinder: !counts.paths.isEmpty,
            badge: nil
        )
    }

    private static func stopped(_ counts: Counts) -> RunPresentation {
        let line = "Stopped · \(counts.completed) of \(counts.total) complete"
        return make(
            counts,
            phase: .stopped,
            leading: line,
            help: "",
            subtitle: line,
            showsColumn: false,
            fraction: counts.fraction,
            caption: "",
            value: "",
            showsFinder: false,
            badge: nil
        )
    }

    private static func summaryCount(_ counts: Counts) -> String {
        "\(counts.completed) of \(counts.total) complete"
    }

    private static func finishedSummary(_ counts: Counts) -> (text: String, help: String) {
        var parts: [String] = []
        if counts.succeeded > 0 { parts.append("\(counts.succeeded) done") }
        if counts.failed > 0 { parts.append("\(counts.failed) failed") }
        var help: [String] = []
        if counts.noSubtitles > 0 {
            help.append(counts.noSubtitles == 1 ? "1 no subtitles" : "\(counts.noSubtitles) no subtitles")
        }
        if counts.imageOnly > 0 {
            help.append(counts.imageOnly == 1 ? "1 image subs only" : "\(counts.imageOnly) image subs only")
        }
        if counts.skipped > 0 {
            help.append(counts.skipped == 1 ? "1 skipped" : "\(counts.skipped) skipped")
        }
        if parts.isEmpty {
            parts = help.isEmpty ? ["Finished"] : help
            return (parts.joined(separator: " · "), "")
        }
        return (parts.joined(separator: " · "), help.joined(separator: " · "))
    }

    private static func make(
        _ counts: Counts,
        phase: RunPhase,
        leading: String,
        help: String,
        subtitle: String,
        showsColumn: Bool,
        fraction: Double,
        caption: String,
        value: String,
        showsFinder: Bool,
        badge: String?
    ) -> RunPresentation {
        RunPresentation(
            phase: phase,
            leadingSummary: leading,
            leadingHelp: help,
            toolbarSubtitle: subtitle,
            showsColumn: showsColumn,
            fraction: min(1, max(0, fraction)),
            caption: caption,
            accessibilityValue: value,
            showsFinder: showsFinder,
            outputPaths: counts.paths,
            dockBadge: badge,
            total: counts.total,
            completed: counts.completed,
            extracting: counts.extracting,
            remaining: counts.remaining,
            succeeded: counts.succeeded,
            failed: counts.failed,
            savedCount: counts.saved,
            existedCount: counts.existed
        )
    }
}
