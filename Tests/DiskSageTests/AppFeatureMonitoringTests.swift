import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
struct AppFeatureMonitoringTests {
    @Test func minuteChecksUseTheClockAndStopWithoutLeakingEffects() async {
        let clock = TestClock()
        let checks = LockIsolated<[CleanupLogEvent]>([])
        let disabledMessage = "Automatic cleanup is disabled."
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
                await store.receive(.automaticCheckLogged(FeatureTestSupport.id(index), false, disabledMessage, nil)) {
                    $0.automaticCheckID = nil
                    $0.lastAutomaticCheckReason = disabledMessage
                    $0.dashboardRevision = 1
                }
                await store.receive(.dashboardLoaded(1, DashboardSnapshot()))
            } else {
                await store.receive(.capacityRead(FeatureTestSupport.id(index), 0, false, 100)) {
                    $0.automaticCheckID = nil
                    $0.dashboardRevision = 2
                }
                await store.receive(.dashboardLoaded(2, DashboardSnapshot()))
            }
        }
        #expect(checks.value.count == 1)
        #expect(checks.value.allSatisfy { $0.trigger == .automatic && $0.event == .check && $0.message == disabledMessage })
        await store.send(.stopMonitoring) { $0.isMonitoring = false; $0.lastAutomaticCheckReason = nil }
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
        let startReason = "Free space is at or below the 15 GiB threshold; starting a scan for low-risk items."
        let store = FeatureTestSupport.store {
            $0.diskSage.preferences = { CleanupPreferences() }
            $0.diskSage.scan = { ScanReport(candidates: [low, high]) }
            $0.diskSage.cleanup = { targets, trigger, _ in
                #expect(targets == [low] && trigger == .automatic); return report
            }
            $0.diskSage.logCheck = { event in checks.withValue { $0.append(event) } }
        }
        await store.send(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(0) }
        await store.receive(.capacityRead(FeatureTestSupport.id(0), 0, false, 100)) {
            $0.freeSpaceBytes = 100; $0.operation = .automaticScan; $0.operationID = FeatureTestSupport.id(0)
        }
        await store.receive(.automaticCheckLogged(FeatureTestSupport.id(0), true, startReason, nil)) {
            $0.automaticCheckID = nil; $0.activityRevision = 1
            $0.lastAutomaticCheckReason = startReason
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
        let startReason = "Free space is at or below the 15 GiB threshold; starting a scan for low-risk items."
        let store = FeatureTestSupport.store {
            $0.diskSage.preferences = { CleanupPreferences() }
            $0.diskSage.logCheck = { _ in throw error }
        }
        await store.send(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(0) }
        await store.receive(.capacityRead(FeatureTestSupport.id(0), 0, false, 100)) {
            $0.freeSpaceBytes = 100; $0.operation = .automaticScan; $0.operationID = FeatureTestSupport.id(0)
        }
        await store.receive(.automaticCheckLogged(FeatureTestSupport.id(0), true, startReason, FeatureFailure(message: error.localizedDescription))) {
            $0.automaticCheckID = nil; $0.operation = .idle; $0.operationID = nil
            $0.errorMessage = "Automatic cleanup check could not be logged: \(error.localizedDescription)"
        }
        await store.finish()
    }

    @Test func transitionOnlyMonitoringSkipsRedundantLogsAndDashboardReloads() async {
        let highSpace: Int64 = 25 * 1_024 * 1_024 * 1_024
        let higherSpace: Int64 = 30 * 1_024 * 1_024 * 1_024
        let lowSpace: Int64 = 10 * 1_024 * 1_024 * 1_024
        let available = LockIsolated<Int64?>(highSpace)
        let checks = LockIsolated<[CleanupLogEvent]>([])
        let dashboardReads = LockIsolated(0)
        let snapshot = DashboardSnapshot(usage: DiskUsageSnapshot(name: "Macintosh HD", totalBytes: 100_000_000_000, availableBytes: highSpace))

        var initial = AppFeature.State()
        initial.diskUsage = snapshot.usage
        let store = FeatureTestSupport.store(initial) {
            $0.diskSage.preferences = { CleanupPreferences() }
            $0.diskSage.capacity = { available.value }
            $0.diskSage.freeSpace = { available.value }
            $0.diskSage.scan = { ScanReport(candidates: []) }
            $0.diskSage.logCheck = { event in checks.withValue { $0.append(event) } }
            $0.diskSage.dashboard = {
                dashboardReads.withValue { $0 += 1 }
                return snapshot
            }
        }

        // First healthy tick logs once; second steady healthy tick updates diskUsage in place with zero log/dashboard reads.
        await store.send(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(0) }
        await store.receive(.capacityRead(FeatureTestSupport.id(0), 0, false, highSpace)) { $0.freeSpaceBytes = highSpace }
        let aboveMsg = "Free space is above the 15 GiB threshold."
        await store.receive(.automaticCheckLogged(FeatureTestSupport.id(0), false, aboveMsg, nil)) {
            $0.automaticCheckID = nil
            $0.lastAutomaticCheckReason = aboveMsg
        }

        available.setValue(higherSpace)
        await store.send(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(1) }
        await store.receive(.capacityRead(FeatureTestSupport.id(1), 0, false, higherSpace)) {
            $0.automaticCheckID = nil
            $0.freeSpaceBytes = higherSpace
            $0.diskUsage = DiskUsageSnapshot(name: "Macintosh HD", totalBytes: 100_000_000_000, availableBytes: higherSpace)
        }
        #expect(checks.value.count == 1)
        #expect(dashboardReads.value == 0)

        // Transition: above -> low triggers mandatory check + scan.
        available.setValue(lowSpace)
        let startMsg = "Free space is at or below the 15 GiB threshold; starting a scan for low-risk items."
        await store.send(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(2) }
        await store.receive(.capacityRead(FeatureTestSupport.id(2), 0, false, lowSpace)) {
            $0.freeSpaceBytes = lowSpace
            $0.diskUsage = DiskUsageSnapshot(name: "Macintosh HD", totalBytes: 100_000_000_000, availableBytes: lowSpace)
            $0.operation = .automaticScan
            $0.operationID = FeatureTestSupport.id(2)
        }
        await store.receive(.automaticCheckLogged(FeatureTestSupport.id(2), true, startMsg, nil)) {
            $0.automaticCheckID = nil
            $0.activityRevision = 1
            $0.lastAutomaticCheckReason = startMsg
            $0.automaticRetryAfter = FeatureTestSupport.epoch.addingTimeInterval(900)
            $0.statusMessage = "Low disk space detected; scanning low-risk items…"
        }
        await store.receive(.scanFinished(FeatureTestSupport.id(2), .automatic, [], lowSpace, snapshot)) {
            $0.candidates = []
            $0.lastScanDate = FeatureTestSupport.epoch
            $0.dashboardRevision = 1
            $0.diskUsage = snapshot.usage
            $0.operation = .idle
            $0.operationID = nil
            $0.statusMessage = "No low-risk items to clean automatically."
        }
        let dashboardReadsAfterScan = dashboardReads.value

        // Transition: -> cooldown logs once, then second cooldown tick suppresses log.
        let cooldownMsg = "Free space is low; waiting for the 15-minute automatic cleanup retry cooldown."
        await store.send(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(3) }
        await store.receive(.capacityRead(FeatureTestSupport.id(3), 1, false, lowSpace)) {
            $0.diskUsage = DiskUsageSnapshot(name: "Macintosh HD", totalBytes: 100_000_000_000, availableBytes: lowSpace)
        }
        await store.receive(.automaticCheckLogged(FeatureTestSupport.id(3), false, cooldownMsg, nil)) {
            $0.automaticCheckID = nil
            $0.lastAutomaticCheckReason = cooldownMsg
        }
        await store.send(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(4) }
        await store.receive(.capacityRead(FeatureTestSupport.id(4), 1, false, lowSpace)) {
            $0.automaticCheckID = nil
        }
        #expect(checks.value.count == 3)
        #expect(dashboardReads.value == dashboardReadsAfterScan)

        // Transition: cooldown -> recovered logs once.
        available.setValue(highSpace)
        await store.send(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(5) }
        await store.receive(.capacityRead(FeatureTestSupport.id(5), 1, false, highSpace)) {
            $0.freeSpaceBytes = highSpace
            $0.diskUsage = DiskUsageSnapshot(name: "Macintosh HD", totalBytes: 100_000_000_000, availableBytes: highSpace)
            $0.automaticRetryAfter = nil
        }
        await store.receive(.automaticCheckLogged(FeatureTestSupport.id(5), false, aboveMsg, nil)) {
            $0.automaticCheckID = nil
            $0.lastAutomaticCheckReason = aboveMsg
        }
        #expect(checks.value.map(\.message) == [aboveMsg, startMsg, cooldownMsg, aboveMsg])
        await store.finish()
    }

    @Test func unavailableCapacityFailsClosedWithoutStartingAutomaticCleanup() async {
        let checks = LockIsolated<[CleanupLogEvent]>([])
        let unavailableMsg = "Available disk space could not be read; automatic cleanup skipped."
        let initialFreeSpace: Int64 = 20 * 1_024 * 1_024 * 1_024
        var initial = AppFeature.State()
        initial.freeSpaceBytes = initialFreeSpace
        let store = FeatureTestSupport.store(initial) {
            $0.diskSage.preferences = { CleanupPreferences() }
            $0.diskSage.capacity = { nil }
            $0.diskSage.freeSpace = { nil }
            $0.diskSage.logCheck = { event in checks.withValue { $0.append(event) } }
        }
        await store.send(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(0) }
        await store.receive(.capacityRead(FeatureTestSupport.id(0), 0, false, nil))
        await store.receive(.automaticCheckLogged(FeatureTestSupport.id(0), false, unavailableMsg, nil)) {
            $0.automaticCheckID = nil
            $0.lastAutomaticCheckReason = unavailableMsg
            $0.dashboardRevision = 1
        }
        await store.receive(.dashboardLoaded(1, DashboardSnapshot()))
        #expect(store.state.freeSpaceBytes == initialFreeSpace)
        #expect(store.state.operation == .idle)
        #expect(checks.value.first?.freeSpaceBefore == nil)

        // Direct automatic scan when capacity cannot be read must also refuse cleanup.
        let low = FeatureTestSupport.candidate("low")
        let scanStore = FeatureTestSupport.store(initial) {
            $0.diskSage.preferences = { CleanupPreferences() }
            $0.diskSage.capacity = { nil }
            $0.diskSage.freeSpace = { nil }
            $0.diskSage.scan = { ScanReport(candidates: [low]) }
        }
        await scanStore.send(.scanRequested(.automatic)) {
            $0.activityRevision = 1
            $0.operation = .automaticScan
            $0.operationID = FeatureTestSupport.id(0)
            $0.automaticRetryAfter = FeatureTestSupport.epoch.addingTimeInterval(900)
            $0.statusMessage = "Low disk space detected; scanning low-risk items…"
        }
        await scanStore.receive(.scanFinished(FeatureTestSupport.id(0), .automatic, [low], nil, DashboardSnapshot())) {
            $0.candidates = [low]
            $0.lastScanDate = FeatureTestSupport.epoch
            $0.dashboardRevision = 1
            $0.operation = .idle
            $0.operationID = nil
            $0.statusMessage = "Automatic cleanup skipped: available disk space could not be read."
        }
        #expect(scanStore.state.freeSpaceBytes == initialFreeSpace)
        await scanStore.finish()
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
