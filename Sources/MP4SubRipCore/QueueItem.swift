import Foundation

// The queue rules Arezhik settled on in PGS2SRT issue #8:
// - Clear Finished removes done, failed, skipped, and canceled rows. It is enabled
//   or dimmed, never hidden, and it never asks for confirmation.
// - The hover ✕ appears only on those same rows. Waiting and working rows use Cancel.
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

    /// Waiting or working. Cancel and Cancel All apply.
    public var isActive: Bool {
        switch self {
        case .waiting, .working: return true
        case .done, .failed, .skipped, .canceled: return false
        }
    }

    /// Clear Finished and the row ✕ apply.
    public var isRemovable: Bool { !isActive }

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

    public init(hasActiveWork: Bool = false, canClearFinished: Bool = false) {
        self.hasActiveWork = hasActiveWork
        self.canClearFinished = canClearFinished
    }

    public static func from(_ items: [QueueItem]) -> CommandFlags {
        CommandFlags(
            hasActiveWork: items.contains { $0.status.isActive },
            canClearFinished: items.contains { $0.status.isRemovable }
        )
    }
}
