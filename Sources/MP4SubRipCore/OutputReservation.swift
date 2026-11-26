import Foundation

// Names claimed by extractions that have not finished writing yet (issue #12).
// Two files dropped into one folder can resolve to the same `.srt`. Checking
// the disk and then writing is a race once more than one file runs.
// - Skip treats a reserved path as already there.
// - Add a number treats a reserved path as already there, so the next job
//   takes `Movie (1).srt`.
// - Overwrite waits until the path is free, then writes. Moves do not overlap.
// Release on success, failure, and cancel. The engine's `defer` does that.

/// Claims final `.srt` paths for one run. Safe to share across extraction tasks.
public final class OutputReservation: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = []

    public init() {}

    /// True when an extraction has claimed `path` and not released it.
    public func isReserved(_ path: String) -> Bool {
        let path = Self.key(path)
        lock.lock()
        defer { lock.unlock() }
        return held.contains(path)
    }

    /// Claims `path` when it is free. False means another job holds it.
    /// Skip and Add a number use that as "already exists" and do not wait.
    public func tryClaim(_ path: String) -> Bool {
        let path = Self.key(path)
        lock.lock()
        defer { lock.unlock() }
        if held.contains(path) { return false }
        held.insert(path)
        return true
    }

    /// Waits until `path` is free, then claims it. Overwrite uses this so two
    /// jobs cannot move onto the same final name at once.
    public func claimExclusive(_ path: String) async {
        let path = Self.key(path)
        lock.lock()
        if !held.contains(path) {
            held.insert(path)
            lock.unlock()
            return
        }
        lock.unlock()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            if !self.held.contains(path) {
                self.held.insert(path)
                self.lock.unlock()
                continuation.resume()
                return
            }
            self.waiters[path, default: []].append(continuation)
            self.lock.unlock()
        }
    }

    /// Drops the claims. A waiter for that path, if there is one, receives the claim.
    public func release(_ paths: [String]) {
        for path in paths {
            release(path)
        }
    }

    public func release(_ path: String) {
        let path = Self.key(path)
        lock.lock()
        if var queue = waiters[path], !queue.isEmpty {
            let next = queue.removeFirst()
            if queue.isEmpty {
                waiters[path] = nil
            } else {
                waiters[path] = queue
            }
            // `path` stays held. The resumed job owns it and must release it.
            lock.unlock()
            next.resume()
            return
        }
        held.remove(path)
        lock.unlock()
    }

    private static func key(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
