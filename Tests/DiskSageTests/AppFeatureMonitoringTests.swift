import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
struct AppFeatureMonitoringTests {
    @Test func minuteChecksUseTheClockAndStopWithoutLeakingEffects() async {
        let clock = TestClock()
        let checks = LockIsolated<[CleanupLogEvent]>([])
        let store = FeatureTestSupport.store {
            $0.continuousClock = clock
            $0.diskSage.logCheck = { event in checks.withValue { $0.append(event) } }
        }
        let monitor = await store.send(.startMonitoring) { $0.isMonitoring = true }
        for index in 0..<2 {
            if index > 0 { await clock.advance(by: .seconds(60)) }
            await store.receive(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(index) }
            if index == 0 {
                await store.receive(.capacityRead(FeatureTestSupport.id(index), 0, false, 100)) { $0.freeSpaceBytes = 100 }
            } else {
                await store.receive(.capacityRead(FeatureTestSupport.id(index), 0, false, 100))
            }
            await store.receive(.automaticCheckLogged(FeatureTestSupport.id(index), false, nil)) {
                $0.automaticCheckID = nil; $0.dashboardRevision = index + 1
            }
            await store.receive(.dashboardLoaded(index + 1, DashboardSnapshot()))
        }
        #expect(checks.value.count == 2)
        #expect(checks.value.allSatisfy { $0.trigger == .automatic && $0.event == .check && $0.message == "Automatic cleanup is disabled." })
        await store.send(.stopMonitoring) { $0.isMonitoring = false }
        await monitor.finish()
        await clock.advance(by: .seconds(60))
        await store.finish()
    }

    @Test func automaticCleanupClaimsTheSharedGateAndOnlyRemovesLowRiskTargets() async {
        let low = FeatureTestSupport.candidate("low")
        let high = FeatureTestSupport.candidate("high", risk: .high)
        let report = CleanupReport(items: [CleanupItemResult(candidate: low, removedBytes: 4096, errorDescription: nil)],
                                   freeSpaceBefore: 100, freeSpaceAfter: 200)
        let checks = LockIsolated<[CleanupLogEvent]>([])
        let store = FeatureTestSupport.store {
            $0.diskSage.preferences = { CleanupPreferences() }
            $0.diskSage.scan = { [low, high] }
            $0.diskSage.cleanup = { targets, trigger, _ in
                #expect(targets == [low] && trigger == .automatic); return report
            }
            $0.diskSage.logCheck = { event in checks.withValue { $0.append(event) } }
        }
        await store.send(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(0) }
        await store.receive(.capacityRead(FeatureTestSupport.id(0), 0, false, 100)) {
            $0.freeSpaceBytes = 100; $0.operation = .automaticScan; $0.operationID = FeatureTestSupport.id(0)
        }
        await store.receive(.automaticCheckLogged(FeatureTestSupport.id(0), true, nil)) {
            $0.automaticCheckID = nil; $0.activityRevision = 1
            $0.automaticRetryAfter = FeatureTestSupport.epoch.addingTimeInterval(900)
            $0.statusMessage = "Low disk space detected; scanning low-risk items…"
        }
        await store.receive(.scanFinished(FeatureTestSupport.id(0), .automatic, [low, high], 100, DashboardSnapshot())) {
            $0.candidates = [low, high]; $0.lastScanDate = FeatureTestSupport.epoch; $0.dashboardRevision = 1
            $0.activityRevision = 2; $0.operation = .automaticCleanup; $0.operationID = FeatureTestSupport.id(1)
            $0.cleanupTotalCount = 1; $0.cleanupCurrentItem = "Preparing cleanup…"; $0.statusMessage = "Deleting approved candidates…"
        }
        await store.receive(.cleanupFinished(FeatureTestSupport.id(1), report, DashboardSnapshot())) {
            $0.operation = .idle; $0.operationID = nil; $0.candidates = [high]; $0.cleanupReport = report
            $0.freeSpaceBytes = 200; $0.lastRecoveredBytes = 100; $0.dashboardRevision = 2
            $0.statusMessage = "Deleted 1 item(s) · \(Int64(4096).diskSize) estimated"
            $0.lastAutomaticCleanup = FeatureTestSupport.epoch; $0.automaticCleanupSummary = $0.statusMessage
        }
        #expect(checks.value.first?.message?.contains("starting a scan") == true)
        await store.finish()
    }

    @Test func failedMandatoryCheckLogReleasesReservationWithoutScanning() async {
        let error = CocoaError(.fileWriteNoPermission)
        let store = FeatureTestSupport.store {
            $0.diskSage.preferences = { CleanupPreferences() }
            $0.diskSage.logCheck = { _ in throw error }
        }
        await store.send(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(0) }
        await store.receive(.capacityRead(FeatureTestSupport.id(0), 0, false, 100)) {
            $0.freeSpaceBytes = 100; $0.operation = .automaticScan; $0.operationID = FeatureTestSupport.id(0)
        }
        await store.receive(.automaticCheckLogged(FeatureTestSupport.id(0), true, FeatureFailure(message: error.localizedDescription))) {
            $0.automaticCheckID = nil; $0.operation = .idle; $0.operationID = nil
            $0.errorMessage = "Automatic cleanup check could not be logged: \(error.localizedDescription)"
        }
        await store.finish()
    }

    @Test func stoppingMonitoringCancelsAnOutstandingCapacityRead() async {
        let clock = TestClock()
        let capacity = AsyncStream<Int64>.makeStream()
        let cancelled = LockIsolated(false)
        capacity.continuation.onTermination = { if case .cancelled = $0 { cancelled.setValue(true) } }
        let store = FeatureTestSupport.store {
            $0.continuousClock = clock
            $0.diskSage.capacity = { for await value in capacity.stream { return value }; return 0 }
        }
        let monitoring = await store.send(.startMonitoring) { $0.isMonitoring = true }
        await store.receive(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(0) }
        await store.send(.stopMonitoring) { $0.isMonitoring = false; $0.automaticCheckID = nil }
        await monitoring.finish()
        await store.finish()
        #expect(cancelled.value)
    }
}
