import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
struct AutomaticCleanupResponsivenessTests {
    nonisolated static let highSpace: Int64 = 20 * 1_024 * 1_024 * 1_024
    nonisolated static let lowSpace: Int64 = 10 * 1_024 * 1_024 * 1_024

    @Test func aThresholdCrossingCleansOnlyLowRiskItemsOnTheNextMinute() async {
        let clock = TestClock()
        let available = LockIsolated(Self.highSpace)
        let low = FeatureTestSupport.candidate("generated"), sensitive = FeatureTestSupport.candidate("sensitive", risk: .high)
        let report = CleanupReport(items: [CleanupItemResult(candidate: low, removedBytes: 4096, errorDescription: nil)],
            freeSpaceBefore: Self.lowSpace, freeSpaceAfter: Self.highSpace)
        let store = FeatureTestSupport.store {
            $0.continuousClock = clock
            $0.diskSage.preferences = { CleanupPreferences() }
            $0.diskSage.capacity = { available.value }; $0.diskSage.freeSpace = { available.value }
            $0.diskSage.scan = { ScanReport(candidates: [low, sensitive]) }
            $0.diskSage.cleanup = { targets, trigger, _ in
                #expect(targets == [low] && trigger == .automatic)
                available.setValue(Self.highSpace)
                return report
            }
        }
        let monitoring = await store.send(.startMonitoring) { $0.isMonitoring = true }
        await store.receive(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(0) }
        await store.receive(.capacityRead(FeatureTestSupport.id(0), 0, false, Self.highSpace)) { $0.freeSpaceBytes = Self.highSpace }
        await store.receive(.automaticCheckLogged(FeatureTestSupport.id(0), false, nil)) {
            $0.automaticCheckID = nil; $0.dashboardRevision = 1
        }
        await store.receive(.dashboardLoaded(1, DashboardSnapshot()))
        available.setValue(Self.lowSpace)
        await clock.advance(by: .seconds(60))
        await store.receive(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(1) }
        await store.receive(.capacityRead(FeatureTestSupport.id(1), 0, false, Self.lowSpace)) {
            $0.freeSpaceBytes = Self.lowSpace; $0.operation = .automaticScan; $0.operationID = FeatureTestSupport.id(1)
        }
        await store.receive(.automaticCheckLogged(FeatureTestSupport.id(1), true, nil)) {
            $0.automaticCheckID = nil; $0.activityRevision = 1
            $0.automaticRetryAfter = FeatureTestSupport.epoch.addingTimeInterval(900)
            $0.statusMessage = "Low disk space detected; scanning low-risk items…"
        }
        await store.receive(.scanFinished(FeatureTestSupport.id(1), .automatic, [low, sensitive], Self.lowSpace, DashboardSnapshot())) {
            $0.candidates = [low, sensitive]; $0.lastScanDate = FeatureTestSupport.epoch; $0.dashboardRevision = 2
            $0.activityRevision = 2; $0.operation = .automaticCleanup; $0.operationID = FeatureTestSupport.id(2)
            $0.cleanupTotalCount = 1; $0.cleanupCurrentItem = "Preparing cleanup…"; $0.statusMessage = "Deleting approved candidates…"
        }
        await store.receive(.cleanupFinished(FeatureTestSupport.id(2), report, DashboardSnapshot())) {
            $0.operation = .idle; $0.operationID = nil; $0.candidates = [sensitive]; $0.cleanupReport = report
            $0.freeSpaceBytes = Self.highSpace; $0.lastRecoveredBytes = Self.highSpace - Self.lowSpace; $0.dashboardRevision = 3
            $0.statusMessage = "Deleted 1 item(s) · \(Int64(4096).diskSize) estimated"
            $0.lastAutomaticCleanup = FeatureTestSupport.epoch; $0.automaticCleanupSummary = $0.statusMessage
        }
        await store.send(.stopMonitoring) { $0.isMonitoring = false }
        await monitoring.finish()
        await store.finish()
    }

    @Test(arguments: [false, true])
    func scansAreRearmedByCooldownExpiryOrRecoveryAboveThreshold(recovered: Bool) async {
        let epoch = FeatureTestSupport.epoch
        let date = LockIsolated(epoch)
        let available = LockIsolated(recovered ? Self.highSpace : Self.lowSpace)
        let checks = LockIsolated<[CleanupLogEvent]>([])
        var initial = AppFeature.State(); initial.automaticRetryAfter = FeatureTestSupport.epoch.addingTimeInterval(900)
        let store = FeatureTestSupport.store(initial) {
            $0.date = .init { date.value }
            $0.diskSage.preferences = { CleanupPreferences() }
            $0.diskSage.capacity = { available.value }; $0.diskSage.freeSpace = { available.value }
            $0.diskSage.scan = { ScanReport(candidates: []) }
            $0.diskSage.logCheck = { event in checks.withValue { $0.append(event) } }
        }
        await store.send(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(0) }
        await store.receive(.capacityRead(FeatureTestSupport.id(0), 0, false, available.value)) {
            $0.freeSpaceBytes = available.value
            if recovered { $0.automaticRetryAfter = nil }
        }
        await store.receive(.automaticCheckLogged(FeatureTestSupport.id(0), false, nil)) {
            $0.automaticCheckID = nil; $0.dashboardRevision = 1
        }
        await store.receive(.dashboardLoaded(1, DashboardSnapshot()))
        #expect(checks.value.first?.message?.contains(recovered ? "above" : "cooldown") == true)
        available.setValue(Self.lowSpace)
        if !recovered { date.setValue(epoch.addingTimeInterval(901)) }
        await store.send(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(1) }
        await store.receive(.capacityRead(FeatureTestSupport.id(1), 0, false, Self.lowSpace)) {
            $0.freeSpaceBytes = Self.lowSpace; $0.operation = .automaticScan; $0.operationID = FeatureTestSupport.id(1)
        }
        await store.receive(.automaticCheckLogged(FeatureTestSupport.id(1), true, nil)) {
            $0.automaticCheckID = nil; $0.activityRevision = 1
            $0.automaticRetryAfter = date.value.addingTimeInterval(900)
            $0.statusMessage = "Low disk space detected; scanning low-risk items…"
        }
        await store.receive(.scanFinished(FeatureTestSupport.id(1), .automatic, [], Self.lowSpace, DashboardSnapshot())) {
            $0.lastScanDate = date.value; $0.dashboardRevision = 2; $0.operation = .idle; $0.operationID = nil
            $0.statusMessage = "No low-risk items to clean automatically."
        }
        await store.finish()
    }

    @Test func changingPreferencesChecksImmediatelyInsteadOfWaitingForTheTimer() async {
        var initial = AppFeature.State(); initial.isMonitoring = true
        initial.automaticRetryAfter = FeatureTestSupport.epoch.addingTimeInterval(900)
        let store = FeatureTestSupport.store(initial)
        await store.send(.monitoringPreferencesChanged) { $0.automaticRetryAfter = nil }
        await store.receive(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(0) }
        await store.receive(.capacityRead(FeatureTestSupport.id(0), 0, false, 100)) { $0.freeSpaceBytes = 100 }
        await store.receive(.automaticCheckLogged(FeatureTestSupport.id(0), false, nil)) {
            $0.automaticCheckID = nil; $0.dashboardRevision = 1
        }
        await store.receive(.dashboardLoaded(1, DashboardSnapshot()))
        await store.finish()
    }
}
