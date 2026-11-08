import Foundation

/// Only queued rows are cancellable. A running Git removal always finishes and is reconciled.
final class WorktreeCancellation: @unchecked Sendable {
    static let shared = WorktreeCancellation()
    private let lock = NSLock()
    private var cancelled: Set<UUID> = []
    func request(_ id: UUID) { lock.lock(); defer { lock.unlock() }; cancelled.insert(id) }
    func contains(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled.contains(id) }
    func finish(_ id: UUID) { lock.lock(); defer { lock.unlock() }; cancelled.remove(id) }
}
