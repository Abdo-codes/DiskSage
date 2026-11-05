import Foundation

struct DiskUsageSnapshot: Equatable, Codable, Sendable {
    let name: String
    let totalBytes: Int64
    let availableBytes: Int64

    init(name: String, totalBytes: Int64, availableBytes: Int64) {
        self.name = name
        self.totalBytes = max(0, totalBytes)
        self.availableBytes = min(max(0, availableBytes), self.totalBytes)
    }

    var usedBytes: Int64 { totalBytes - availableBytes }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }

    static func read() throws -> DiskUsageSnapshot {
        let values = try URL(fileURLWithPath: "/System/Volumes/Data").resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ])
        guard let total = values.volumeTotalCapacity, total > 0,
              let available = values.volumeAvailableCapacityForImportantUsage else {
            throw CocoaError(.fileReadUnknown)
        }
        return DiskUsageSnapshot(name: values.volumeName ?? "Macintosh HD", totalBytes: Int64(total), availableBytes: available)
    }
}

struct CleanupBreakdown {
    struct Category: Identifiable {
        let category: CandidateCategory
        let bytes: Int64
        var id: CandidateCategory { category }
    }

    let categories: [Category]
    let lowRiskBytes: Int64
    let totalBytes: Int64
    var reviewBytes: Int64 { totalBytes - lowRiskBytes }

    init(candidates: [CleanupCandidate]) {
        categories = CandidateCategory.allCases.compactMap { category in
            let size = candidates.filter { $0.category == category }.reduce(Int64(0)) { $0 + $1.size }
            return size > 0 ? Category(category: category, bytes: size) : nil
        }
        totalBytes = candidates.reduce(0) { $0 + $1.size }
        lowRiskBytes = candidates.filter { $0.risk == .low }.reduce(0) { $0 + $1.size }
    }
}

struct DashboardPresentation {
    enum PrimaryAction { case scan, review, scanProgress, advisorProgress, cleanupProgress, confirmCleanup }
    let operation: AppOperation
    let hasScanned: Bool
    let candidateCount: Int
    let lowRiskCount: Int
    let awaitingConfirmation: Bool

    var primaryAction: PrimaryAction {
        if awaitingConfirmation { return .confirmCleanup }
        switch operation {
        case .scanning, .automaticScan: return .scanProgress
        case .advising: return .advisorProgress
        case .cleaning, .automaticCleanup: return .cleanupProgress
        case .idle: return candidateCount == 0 ? .scan : .review
        }
    }
    var isWorking: Bool { operation != .idle }
    var canCleanNow: Bool {
        operation == .idle && !awaitingConfirmation && (!hasScanned || lowRiskCount > 0)
    }
    var primaryTitle: LocalizedStringResource {
        switch primaryAction {
        case .confirmCleanup: return "Confirm cleanup…"
        case .scanProgress: return "View scan progress"
        case .advisorProgress: return "View advisor progress"
        case .cleanupProgress: return "View cleanup progress"
        case .review: return "Review \(candidateCount) items"
        case .scan: return hasScanned ? "Scan again" : "Scan for cleanup items"
        }
    }
}

extension AppFeature.State {
    var dashboardPresentation: DashboardPresentation {
        DashboardPresentation(operation: operation, hasScanned: lastScanDate != nil,
            candidateCount: candidates.count, lowRiskCount: lowRiskCandidates.count,
            awaitingConfirmation: pendingDeletionRequest != nil)
    }
}
