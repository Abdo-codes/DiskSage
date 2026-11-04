import Foundation

/// One lock for infrequent worker publications; per-file counting stays local to each worker.
final class ParallelCleanupEntries: @unchecked Sendable {
    private let lock = NSLock()
    private let updates: AsyncStream<CleanupProgress>.Continuation
    private var counts: [Int: Int] = [:]
    private var removed = 0
    private var lastUpdate = ContinuousClock.now

    init(updates: AsyncStream<CleanupProgress>.Continuation) { self.updates = updates }
    var total: Int { lock.withLock { removed } }

    func record(index: Int, count: Int) {
        lock.withLock {
            removed += count - (counts[index] ?? 0)
            counts[index] = count
            let now = ContinuousClock.now
            if lastUpdate.duration(to: now) >= .milliseconds(250) {
                lastUpdate = now
                updates.yield(.entriesRemoved(removed))
            }
        }
    }

    func publish() {
        lock.withLock {
            lastUpdate = ContinuousClock.now
            updates.yield(.entriesRemoved(removed))
        }
    }
}
