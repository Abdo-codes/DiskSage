import Foundation

struct CleanupRunSummary: Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let trigger: CleanupTrigger
    let items: [CleanupLogEvent]
    let succeededCount: Int
    let failedCount: Int
    let estimatedRemovedBytes: Int64
    let availableSpaceChange: Int64?
    let error: String?
    var hasWarnings: Bool { failedCount > 0 || error != nil }

    var itemNames: [String] {
        items.filter { $0.succeeded == true }.map(\.displayName)
    }

    var itemDescription: String {
        guard !itemNames.isEmpty else {
            if succeededCount > 0 { return "Item details are no longer in the retained log." }
            return hasWarnings ? "No items confirmed fully removed." : "No items removed."
        }
        let names = itemNames.prefix(2).joined(separator: ", ")
        let remainder = max(0, succeededCount - min(2, itemNames.count))
        return remainder > 0 ? "\(names), and \(remainder) more" : names
    }
}

enum CleanupHistory {
    static func summaries(from events: [CleanupLogEvent], limit: Int = 20) -> [CleanupRunSummary] {
        let grouped = Dictionary(grouping: events, by: \.runID)
        return events.reversed().filter { $0.event == .finished }.prefix(max(0, limit)).map { finished in
            let items = (grouped[finished.runID] ?? []).filter { $0.event == .itemFinished }
            let failures = finished.failedCount ?? items.filter { $0.succeeded == false }.count
            let count = finished.candidateCount ?? items.count
            return CleanupRunSummary(
                id: finished.runID, timestamp: finished.timestamp, trigger: finished.trigger,
                items: items, succeededCount: max(0, count - failures), failedCount: failures,
                estimatedRemovedBytes: finished.estimatedRemovedBytes ?? 0,
                availableSpaceChange: finished.actualRecoveredBytes, error: finished.message
            )
        }
    }
}

extension CleanupLogEvent {
    var displayName: String {
        if let name, !name.isEmpty { return name }
        guard let path else { return "Unknown item" }
        if path.hasSuffix("/CoreSimulator/Devices") { return "Simulator devices" }
        if path.hasSuffix("/Xcode/DerivedData") { return "Xcode DerivedData" }
        if path.hasSuffix("/Xcode/Archives") { return "Xcode archives" }
        let url = URL(fileURLWithPath: path)
        if [".build", "build"].contains(url.lastPathComponent) {
            return "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
        }
        return url.lastPathComponent
    }
}
