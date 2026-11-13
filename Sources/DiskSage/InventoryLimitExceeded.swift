import Foundation

/// A folder had more entries than a safe walk may read. The walk stops and lists nothing,
/// so a partial list is never used for deletion. A scan reports this; it does not hide it.
struct InventoryLimitExceeded: LocalizedError, Equatable, Sendable {
    let limit: Int
    var errorDescription: String? { "It has more than \(limit.formatted()) files and folders, so DiskSage did not check it." }
}
