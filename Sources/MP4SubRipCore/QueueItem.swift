import Foundation

// The queue rules Arezhik settled on in PGS2SRT issue #8:
// - Clear Finished removes done, failed, skipped, and canceled rows. It is enabled
//   or dimmed, never hidden, and it never asks for confirmation.
// - The hover ✕ appears only on those same rows. During a run, Pending and Extracting rows use Cancel.
// - Removing a row never deletes the output file on disk.
// - An empty queue goes back to the drop screen.

/// Where one queued file is.
public enum JobStatus: Equatable, Sendable {
    case waiting
    /// `completed` of `total` units, such as pictures or tracks. `total` 0 means unknown.
    case working(completed: Int, total: Int)
    case done(outputPath: String)
    case failed(reason: String)
    case skipped(reason: String)
    case canceled

    /// Waiting or working. Cancel applies. Clear Finished does not.
    public var isActive: Bool {
        switch self {
        case .waiting, .working: return true
        case .done, .failed, .skipped, .canceled: return false
        }
    }

    /// A file the engine is reading right now.
    public var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    /// Clear Finished and the row ✕ apply.
    public var isRemovable: Bool { !isActive }

    /// The one line shown on the row. Words match the design spec:
    /// Pending, Extracting, Done, Failed, Cancelled, Skipped.
    public var summary: String {
        switch self {
        case .waiting:
            return "Pending"
        case .working:
            return "Extracting"
        case let .done(outputPath):
            let name = (outputPath as NSString).lastPathComponent
            return name.isEmpty ? "Done" : "Done · \(name)"
        case let .failed(reason):
            return "Failed · \(reason)"
        case let .skipped(reason):
            return "Skipped · \(reason)"
        case .canceled:
            return "Cancelled"
        }
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

    /// Failed rows offer Show Error…. Skipped rows keep the gray status line and a tooltip.
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

    public init(id: UUID = UUID(), path: String, status: JobStatus = .waiting) {
        self.id = id
        self.path = path
        self.status = status
    }

    public var fileName: String { (path as NSString).lastPathComponent }
}

/// The few values menu commands depend on. The app publishes these only when one
/// of them changes, so open menus do not rebuild on every progress tick (PGS2SRT #35).
public struct CommandFlags: Equatable, Sendable {
    public var hasActiveWork: Bool
    public var canClearFinished: Bool
    /// Idle, and at least one row is Pending. Extract Subtitles uses this.
    public var canExtract: Bool
    /// Extract was pressed and the run has not stopped or finished.
    public var isRunning: Bool

    public init(
        hasActiveWork: Bool = false,
        canClearFinished: Bool = false,
        canExtract: Bool = false,
        isRunning: Bool = false
    ) {
        self.hasActiveWork = hasActiveWork
        self.canClearFinished = canClearFinished
        self.canExtract = canExtract
        self.isRunning = isRunning
    }

    /// `isRunning` is the Extract/Stop latch, not "any row looks active".
    /// `hasLiveTask` keeps Extract disabled while a cancelled file is still
    /// deleting its partial output.
    public static func from(
        _ items: [QueueItem],
        isRunning: Bool = false,
        hasLiveTask: Bool = false
    ) -> CommandFlags {
        CommandFlags(
            hasActiveWork: items.contains { $0.status.isActive },
            canClearFinished: items.contains { $0.status.isRemovable },
            canExtract: !isRunning && !hasLiveTask && items.contains { $0.status == .waiting },
            isRunning: isRunning
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
}

/// Which row Extract runs next, and what Stop or Cancel does to the list.
/// The app still runs the engine and deletes a half-written SRT. This only
/// updates rows.
public enum QueueRunRules {
    /// The next Pending row. `held` rows were cancelled during this run and
    /// wait for the next Extract. Done, Failed, and Skipped rows are not chosen.
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
