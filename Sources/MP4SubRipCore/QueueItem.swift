import Foundation

// Queue rules for Phase 2 (issues #7–#10):
// - Clear Processed removes done, skipped-exists, no-subtitles, image-only,
//   other skipped, and canceled rows. Failed rows stay so they can be retried.
//   Clear All Finished also removes Failed. Both are disabled during a run,
//   enabled or dimmed otherwise, and never ask for confirmation.
// - The row ✕ removes any row that is not extracting, including Pending and
//   Waiting during a run. The extracting row has no ✕ (Stop first).
// - Removing a row never deletes the output file on disk.
// - An empty queue goes back to the drop screen.
// - Existing .srt files follow Settings (Skip / Overwrite / Add a number).
//   There is no per-file prompt.

/// Where one queued file is.
public enum JobStatus: Equatable, Sendable {
    /// Tracks are being read. Not chosen by Extract.
    case probing
    case waiting
    /// `completed` of `total` units, such as cues or tracks. `total` 0 means unknown.
    case working(completed: Int, total: Int)
    /// At least one SRT was written. `skippedExists` names files left untouched.
    case done(written: [String], skippedExists: [String])
    /// Every planned SRT was already on disk. Nothing was written.
    case skippedExists(paths: [String])
    case noSubtitles
    case imageSubsOnly
    case failed(reason: String)
    case skipped(reason: String)
    case canceled

    /// Waiting or extracting. Clear Processed does not apply.
    public var isActive: Bool {
        switch self {
        case .waiting, .working: return true
        case .probing, .done, .skippedExists, .noSubtitles, .imageSubsOnly, .failed, .skipped, .canceled:
            return false
        }
    }

    /// A file the engine is reading right now. This row cannot be removed.
    public var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    /// Row ✕, Delete, and Remove from Queue. Pending rows can go during a run.
    public var canRemove: Bool { !isWorking }

    /// Clear Processed. Failed rows are kept.
    public var clearsWithProcessed: Bool {
        switch self {
        case .done, .skippedExists, .noSubtitles, .imageSubsOnly, .skipped, .canceled:
            return true
        case .probing, .waiting, .working, .failed:
            return false
        }
    }

    /// Clear All Finished. Failed rows go too. Pending and extracting stay.
    public var clearsWithAllFinished: Bool {
        if case .failed = self { return true }
        return clearsWithProcessed
    }

    /// Retry on Failed, and on Cancelled when that state is used.
    public var canRetry: Bool {
        switch self {
        case .failed, .canceled: return true
        default: return false
        }
    }

    /// Paths Reveal and Open Subtitle can use. Empty until something was written or skipped because it existed.
    public var outputPaths: [String] {
        switch self {
        case let .done(written, skipped):
            return written + skipped
        case let .skippedExists(paths):
            return paths
        default:
            return []
        }
    }

    /// 0...100 while extracting with a known total. Nil when the total is unknown.
    public var progressPercent: Int? {
        guard case let .working(completed, total) = self, total > 0 else { return nil }
        let raw = Int((Double(completed) / Double(total) * 100).rounded())
        return min(100, max(0, raw))
    }

    /// The one line shown on the row when nothing is running.
    /// Waiting rows say "Waiting…" only while a run is active; see `QueueRowText`.
    public var summary: String {
        QueueRowText.summary(self, runIsActive: false)
    }

    /// The engine's full reason, for a tooltip or Show Error….
    /// Nil when the status is only a word.
    public var detail: String? {
        switch self {
        case let .failed(reason):
            return reason
        case let .skipped(reason):
            return reason
        default:
            return nil
        }
    }

    /// Failed rows offer Show Error…. Other rows keep a tooltip when they have one.
    public var offersErrorDetail: Bool {
        if case .failed = self { return true }
        return false
    }

    /// True when `next` only moves a progress counter. Those updates are throttled;
    /// every other change (start, done, failed) is published right away.
    public func isProgressTick(to next: JobStatus) -> Bool {
        if case .working = self, case .working = next { return true }
        return false
    }
}

/// One row in the queue.
public struct QueueItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var path: String
    public var status: JobStatus
    /// Filled when probe finishes. Empty while tracks are still loading.
    public var tracks: [SubtitleTrack]
    /// Extra sentence for a settled row, such as why a closed-caption track was not extracted.
    public var statusNote: String?

    public init(
        id: UUID = UUID(),
        path: String,
        status: JobStatus = .waiting,
        tracks: [SubtitleTrack] = [],
        statusNote: String? = nil
    ) {
        self.id = id
        self.path = path
        self.status = status
        self.tracks = tracks
        self.statusNote = statusNote
    }

    public var fileName: String { (path as NSString).lastPathComponent }
}

/// The few values menu commands depend on. The app publishes these only when one
/// of them changes, so open menus do not rebuild on every progress tick (PGS2SRT #35).
public struct CommandFlags: Equatable, Sendable {
    public var hasActiveWork: Bool
    public var canClearProcessed: Bool
    public var canClearAllFinished: Bool
    /// Idle, and at least one row is Pending. Extract Subtitles uses this.
    public var canExtract: Bool
    /// Extract was pressed and the run has not stopped or finished.
    public var isRunning: Bool
    public var canRetry: Bool
    public var canReveal: Bool
    public var canShowVideo: Bool
    public var canOpenSubtitle: Bool
    public var canShowError: Bool
    public var canRemoveSelection: Bool

    public init(
        hasActiveWork: Bool = false,
        canClearProcessed: Bool = false,
        canClearAllFinished: Bool = false,
        canExtract: Bool = false,
        isRunning: Bool = false,
        canRetry: Bool = false,
        canReveal: Bool = false,
        canShowVideo: Bool = false,
        canOpenSubtitle: Bool = false,
        canShowError: Bool = false,
        canRemoveSelection: Bool = false
    ) {
        self.hasActiveWork = hasActiveWork
        self.canClearProcessed = canClearProcessed
        self.canClearAllFinished = canClearAllFinished
        self.canExtract = canExtract
        self.isRunning = isRunning
        self.canRetry = canRetry
        self.canReveal = canReveal
        self.canShowVideo = canShowVideo
        self.canOpenSubtitle = canOpenSubtitle
        self.canShowError = canShowError
        self.canRemoveSelection = canRemoveSelection
    }

    /// `isRunning` is the Extract/Stop latch, not "any row looks active".
    /// `hasLiveTask` keeps Extract disabled while a cancelled file is still
    /// deleting its partial output. Probe tasks must not be passed as `hasLiveTask`.
    /// Clear stays disabled for the whole run. Selection flags follow the selected rows.
    public static func from(
        _ items: [QueueItem],
        isRunning: Bool = false,
        hasLiveTask: Bool = false,
        selection: Set<UUID> = []
    ) -> CommandFlags {
        let actions = RowActionSet.forSelection(items, ids: selection)
        return CommandFlags(
            hasActiveWork: items.contains { $0.status.isActive },
            canClearProcessed: !isRunning && items.contains { $0.status.clearsWithProcessed },
            canClearAllFinished: !isRunning && items.contains { $0.status.clearsWithAllFinished },
            canExtract: !isRunning && !hasLiveTask && items.contains { $0.status == .waiting },
            isRunning: isRunning,
            canRetry: actions.retry,
            canReveal: actions.reveal,
            canShowVideo: actions.showVideo,
            canOpenSubtitle: actions.openSubtitle,
            canShowError: actions.showError,
            canRemoveSelection: actions.remove
        )
    }
}

/// The result of adding paths to a queue that already has rows.
public struct QueueAddition: Equatable, Sendable {
    public var items: [QueueItem]
    /// Rows already in the queue whose path was added again. No second row is created.
    public var duplicateIDs: [UUID]
    public var addedCount: Int

    public init(items: [QueueItem], duplicateIDs: [UUID], addedCount: Int) {
        self.items = items
        self.duplicateIDs = duplicateIDs
        self.addedCount = addedCount
    }
}

/// How paths join the queue. A path that is already present is a duplicate,
/// whatever its status, and is not added again.
public enum QueueList {
    public static func adding(_ paths: [String], to items: [QueueItem]) -> QueueAddition {
        var items = items
        var duplicateIDs: [UUID] = []
        var addedCount = 0
        for path in paths {
            if let existing = items.first(where: { $0.path == path }) {
                if !duplicateIDs.contains(existing.id) {
                    duplicateIDs.append(existing.id)
                }
            } else {
                items.append(QueueItem(path: path))
                addedCount += 1
            }
        }
        return QueueAddition(items: items, duplicateIDs: duplicateIDs, addedCount: addedCount)
    }

    /// Rows that were not already in the queue start out as "Reading tracks…".
    public static func markingNewRowsForProbe(
        _ items: [QueueItem],
        existingIDs: Set<UUID>
    ) -> (items: [QueueItem], probeIDs: [UUID]) {
        var items = items
        var probeIDs: [UUID] = []
        for index in items.indices where !existingIDs.contains(items[index].id) {
            items[index].status = .probing
            probeIDs.append(items[index].id)
        }
        return (items, probeIDs)
    }
}

/// Which row Extract runs next, and what Stop or Cancel does to the list.
/// The app still runs the engine and deletes a half-written SRT. This only
/// updates rows.
public enum QueueRunRules {
    /// The next Pending row. `held` rows were cancelled during this run and
    /// wait for the next Extract. Probing, failed, and already-settled rows are not chosen.
    public static func nextPending(in items: [QueueItem], held: Set<UUID>) -> UUID? {
        items.first { $0.status == .waiting && !held.contains($0.id) }?.id
    }

    /// Stop. A row that is extracting goes back to Pending. Finished rows stay finished.
    public static func stopped(_ items: [QueueItem]) -> [QueueItem] {
        items.map { item in
            guard item.status.isWorking else { return item }
            var item = item
            item.status = .waiting
            return item
        }
    }

    /// Cancel one row. An active row goes back to Pending so the next Extract
    /// can pick it up. A finished row is left alone.
    public static func cancelled(_ items: [QueueItem], id: UUID) -> [QueueItem] {
        items.map { item in
            guard item.id == id, item.status.isActive else { return item }
            var item = item
            item.status = .waiting
            return item
        }
    }
}
