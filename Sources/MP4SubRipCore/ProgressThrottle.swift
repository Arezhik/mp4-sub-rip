import Foundation

/// Limits how often progress counters reach the UI.
///
/// New in this template (PGS2SRT does not have it yet): PGS2SRT published every
/// progress tick, and the open menu bar menus flickered while a file converted
/// (issue #35). Publish status changes right away, and let this gate the counters
/// to about 10 updates a second. Keep one throttle per queue item.
public struct ProgressThrottle: Sendable {
    public static let defaultInterval: TimeInterval = 0.1

    public let minimumInterval: TimeInterval
    private var lastPublished: Date?

    public init(minimumInterval: TimeInterval = ProgressThrottle.defaultInterval) {
        self.minimumInterval = max(0, minimumInterval)
    }

    /// True when this tick should be shown. `force` is for the first and last tick.
    public mutating func shouldPublish(at now: Date = Date(), force: Bool = false) -> Bool {
        if !force, let lastPublished, now.timeIntervalSince(lastPublished) < minimumInterval {
            return false
        }
        lastPublished = now
        return true
    }

    public mutating func reset() {
        lastPublished = nil
    }
}
