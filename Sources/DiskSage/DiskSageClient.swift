import AppKit
import ComposableArchitecture
import Foundation

struct CleanupPreferences: Equatable, Sendable {
    var automaticEnabled = true
    var thresholdGiB = 15
    var agentPolicy: AgentCleanupPolicy = .confirm
    var builtInCleanupEnabled = false

    static func read() -> Self {
        let defaults = UserDefaults.standard
        return Self(automaticEnabled: defaults.object(forKey: "automaticCleanupEnabled") as? Bool ?? true,
            thresholdGiB: defaults.object(forKey: "cleanupThresholdGiB") as? Int ?? 15,
            agentPolicy: .current, builtInCleanupEnabled: defaults.bool(forKey: "builtInAgentCleanupEnabled"))
    }
}

struct DashboardSnapshot: Equatable, Sendable {
    var usage: DiskUsageSnapshot?
    var history: [CleanupRunSummary] = []
    var historyError: String?
}

struct FeatureFailure: Error, Equatable, Sendable {
    let message: String
}

struct DiskSageClient: Sendable {
    var scan: @Sendable () async -> [CleanupCandidate]
    var advise: AdvisorAction
    var cleanup: CleanupAction
    var dashboard: @Sendable () async -> DashboardSnapshot
    var freeSpace: @Sendable () -> Int64
    var capacity: @Sendable () async -> Int64
    var preferences: @Sendable () -> CleanupPreferences
    var logCheck: @Sendable (CleanupLogEvent) async throws -> Void
    var openLogs: @Sendable () async -> String?
}

extension DiskSageClient: DependencyKey {
    static let liveValue = Self(
        scan: { await DiskScanner().scan() },
        advise: { try await AgentAdvisor().recommend(candidates: $0, configuration: $1) },
        cleanup: { await CleanupService().delete($0, trigger: $1, progress: $2) },
        dashboard: {
            await Task.detached(priority: .utility) {
                var result = DashboardSnapshot(usage: try? DiskUsageSnapshot.read())
                do { result.history = try CleanupLogger.shared.recentCleanups() }
                catch { result.historyError = error.localizedDescription }
                return result
            }.value
        },
        freeSpace: { availableSpace() }, capacity: { availableSpace() },
        preferences: { .read() },
        logCheck: { event in try await Task.detached(priority: .utility) { try CleanupLogger.shared.append(event) }.value },
        openLogs: {
            await MainActor.run {
                do {
                    try CleanupLogger.shared.prepareDirectory()
                    return NSWorkspace.shared.open(CleanupLogger.shared.directory) ? nil : "The cleanup log folder could not be opened."
                } catch { return error.localizedDescription }
            }
        })

    static let testValue: Self = Self(
        scan: unimplemented("DiskSageClient.scan", placeholder: []),
        advise: unimplemented("DiskSageClient.advise"), cleanup: unimplemented("DiskSageClient.cleanup", placeholder: CleanupReport(items: [], freeSpaceBefore: 0, freeSpaceAfter: 0)),
        dashboard: { DashboardSnapshot() }, freeSpace: { 100 }, capacity: { 100 },
        preferences: { CleanupPreferences(automaticEnabled: false) },
        logCheck: { _ in }, openLogs: { nil })

    static func availableSpace() -> Int64 {
        let values = try? URL(fileURLWithPath: "/System/Volumes/Data")
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

extension DependencyValues {
    var diskSage: DiskSageClient {
        get { self[DiskSageClient.self] }
        set { self[DiskSageClient.self] = newValue }
    }
}
