import Foundation

/// Owned exclusively by the synchronous deletion worker; no task or UI hop per file.
final class CleanupEntryCounter: @unchecked Sendable {
    let emit: (Int) -> Void
    private(set) var removedCount = 0

    init(emit: @escaping (Int) -> Void) { self.emit = emit }
    private var lastUpdate = ContinuousClock.now

    func recordRemoved() {
        removedCount += 1
        // Check the clock in batches and publish at most four updates per second.
        guard removedCount.isMultiple(of: 128) else { return }
        let now = ContinuousClock.now
        guard lastUpdate.duration(to: now) >= .milliseconds(250) else { return }
        lastUpdate = now
        emit(removedCount)
    }

    func flush() { emit(removedCount) }
}
