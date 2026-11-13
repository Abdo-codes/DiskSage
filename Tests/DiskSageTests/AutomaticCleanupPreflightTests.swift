import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
struct AutomaticCleanupPreflightTests {
    enum Change: CaseIterable { case disabled, spaceRecovered, thresholdLowered }

    @Test(arguments: Change.allCases)
    func changesDuringAnAutomaticScanPreventDeletion(change: Change) async {
        let candidate = FeatureTestSupport.candidate()
        let scan = AsyncStream<[CleanupCandidate]>.makeStream()
        let preferences = LockIsolated(CleanupPreferences())
        let initialSpace: Int64 = 10 * 1_024 * 1_024 * 1_024
        let available = LockIsolated(initialSpace)
        let store = FeatureTestSupport.store {
            $0.diskSage.preferences = { preferences.value }
            $0.diskSage.capacity = { available.value }
            $0.diskSage.freeSpace = { available.value }
            $0.diskSage.scan = { for await result in scan.stream { return ScanReport(candidates: result) }; return ScanReport(candidates: []) }
        }
        await store.send(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(0) }
        await store.receive(.capacityRead(FeatureTestSupport.id(0), 0, false, initialSpace)) {
            $0.freeSpaceBytes = initialSpace; $0.operation = .automaticScan; $0.operationID = FeatureTestSupport.id(0)
        }
        await store.receive(.automaticCheckLogged(FeatureTestSupport.id(0), true, nil)) {
            $0.automaticCheckID = nil; $0.activityRevision = 1
            $0.automaticRetryAfter = FeatureTestSupport.epoch.addingTimeInterval(900)
            $0.statusMessage = "Low disk space detected; scanning low-risk items…"
        }
        switch change {
        case .disabled: preferences.withValue { $0.automaticEnabled = false }
        case .spaceRecovered: available.setValue(20 * 1_024 * 1_024 * 1_024)
        case .thresholdLowered: preferences.withValue { $0.thresholdGiB = 5 }
        }
        scan.continuation.yield([candidate])
        await store.receive(.scanFinished(FeatureTestSupport.id(0), .automatic, [candidate], available.value, DashboardSnapshot())) {
            $0.candidates = [candidate]; $0.lastScanDate = FeatureTestSupport.epoch; $0.dashboardRevision = 1
            $0.freeSpaceBytes = available.value; $0.operation = .idle; $0.operationID = nil
            $0.statusMessage = change == .disabled
                ? "Automatic cleanup skipped: disabled in Settings."
                : "Automatic cleanup skipped: free space is above the \(preferences.value.thresholdGiB) GiB threshold."
        }
        await store.finish()
    }

    @Test func automaticScanCanBeCancelledBeforeAnyDeletion() async {
        let scan = AsyncStream<[CleanupCandidate]>.makeStream()
        let cancelled = LockIsolated(false)
        scan.continuation.onTermination = { if case .cancelled = $0 { cancelled.setValue(true) } }
        let store = FeatureTestSupport.store {
            $0.diskSage.scan = { for await result in scan.stream { return ScanReport(candidates: result) }; return ScanReport(candidates: []) }
        }
        let task = await store.send(.scanRequested(.automatic)) {
            $0.activityRevision = 1; $0.operation = .automaticScan; $0.operationID = FeatureTestSupport.id(0)
            $0.automaticRetryAfter = FeatureTestSupport.epoch.addingTimeInterval(900)
            $0.statusMessage = "Low disk space detected; scanning low-risk items…"
        }
        #expect(store.state.isScanning && !store.state.isCleaning)
        #expect(store.state.dashboardPresentation.primaryAction == .scanProgress)
        await store.send(.cancelOperation) {
            $0.activityRevision = 2; $0.operation = .idle; $0.operationID = nil; $0.statusMessage = "Operation cancelled"
        }
        await task.finish()
        #expect(cancelled.value)
        await store.send(.scanFinished(FeatureTestSupport.id(0), .automatic, [FeatureTestSupport.candidate()], 100, DashboardSnapshot()))
        await store.finish()
    }

    @Test(arguments: [false, true])
    func automaticScanWithNoEligibleTargetsDoesNotStartAnEmptyCleanup(sensitiveOnly: Bool) async {
        let candidates = sensitiveOnly ? [FeatureTestSupport.candidate(risk: .high)] : []
        let store = FeatureTestSupport.store {
            $0.diskSage.preferences = { CleanupPreferences() }
            $0.diskSage.scan = { ScanReport(candidates: candidates) }
        }
        await store.send(.scanRequested(.automatic)) {
            $0.activityRevision = 1; $0.operation = .automaticScan; $0.operationID = FeatureTestSupport.id(0)
            $0.automaticRetryAfter = FeatureTestSupport.epoch.addingTimeInterval(900)
            $0.statusMessage = "Low disk space detected; scanning low-risk items…"
        }
        await store.receive(.scanFinished(FeatureTestSupport.id(0), .automatic, candidates, 100, DashboardSnapshot())) {
            $0.candidates = candidates; $0.lastScanDate = FeatureTestSupport.epoch; $0.dashboardRevision = 1
            $0.freeSpaceBytes = 100; $0.operation = .idle; $0.operationID = nil
            $0.statusMessage = "No low-risk items to clean automatically."
        }
        await store.finish()
    }
}
