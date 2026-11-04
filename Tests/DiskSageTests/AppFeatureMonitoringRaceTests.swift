import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
struct AppFeatureMonitoringRaceTests {
    @Test(arguments: [false, true])
    func aCapacityResponseCannotBypassConfirmationEvenAfterItWasCancelled(cancelConfirmation: Bool) async {
        let low = FeatureTestSupport.candidate()
        let capacity = AsyncStream<Int64>.makeStream()
        let checks = LockIsolated<[CleanupLogEvent]>([])
        let store = FeatureTestSupport.store(.init(candidates: [low], lastScanDate: FeatureTestSupport.epoch)) {
            $0.diskSage.preferences = { CleanupPreferences() }
            $0.diskSage.capacity = { for await value in capacity.stream { return value }; return 0 }
            $0.diskSage.logCheck = { event in checks.withValue { $0.append(event) } }
        }
        await store.send(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(0) }
        let request = DeletionRequest(id: FeatureTestSupport.id(1), candidates: [low])
        await store.send(.requestDeletion([low])) {
            $0.activityRevision = 1; $0.pendingDeletionRequest = request; $0.statusMessage = "Review cleanup before deleting."
        }
        if cancelConfirmation {
            await store.send(.cancelOperation) {
                $0.activityRevision = 2; $0.pendingDeletionRequest = nil; $0.statusMessage = "Cleanup cancelled"
            }
        }
        capacity.continuation.yield(100)
        await store.receive(.capacityRead(FeatureTestSupport.id(0), 0, false, 100)) { $0.freeSpaceBytes = 100 }
        await store.receive(.automaticCheckLogged(FeatureTestSupport.id(0), false, nil)) {
            $0.automaticCheckID = nil; $0.dashboardRevision = 1
        }
        await store.receive(.dashboardLoaded(1, DashboardSnapshot()))
        #expect(checks.value.first?.message?.contains("Skipped") == true)
        await store.finish()
    }

    @Test func aCheckStartedDuringDeletionCannotStartCleanupAfterDeletionFinishes() async {
        let low = FeatureTestSupport.candidate()
        let finish = AsyncStream<Bool>.makeStream()
        let capacity = AsyncStream<Int64>.makeStream()
        let report = CleanupReport(items: [CleanupItemResult(candidate: low, removedBytes: 4096, errorDescription: nil)],
                                   freeSpaceBefore: 100, freeSpaceAfter: 200)
        let store = FeatureTestSupport.store(.init(candidates: [low], selection: [low.id])) {
            $0.diskSage.preferences = { CleanupPreferences() }
            $0.diskSage.capacity = { for await value in capacity.stream { return value }; return 0 }
            $0.diskSage.cleanup = { _, _, _ in for await _ in finish.stream { break }; return report }
        }
        await store.send(.deleteApproved([low], .manual)) {
            $0.activityRevision = 1; $0.operation = .cleaning; $0.operationID = FeatureTestSupport.id(0)
            $0.cleanupTotalCount = 1; $0.cleanupCurrentItem = "Preparing cleanup…"; $0.statusMessage = "Deleting approved candidates…"
        }
        await store.send(.monitorTick) { $0.automaticCheckID = FeatureTestSupport.id(1) }
        finish.continuation.yield(true)
        await store.receive(.cleanupFinished(FeatureTestSupport.id(0), report, DashboardSnapshot())) {
            $0.operation = .idle; $0.operationID = nil; $0.candidates = []; $0.selection = []; $0.cleanupReport = report
            $0.freeSpaceBytes = 200; $0.lastRecoveredBytes = 100; $0.dashboardRevision = 1
            $0.statusMessage = "Deleted 1 item(s) · \(Int64(4096).diskSize) estimated"
        }
        capacity.continuation.yield(100)
        await store.receive(.capacityRead(FeatureTestSupport.id(1), 1, true, 100)) { $0.freeSpaceBytes = 100 }
        await store.receive(.automaticCheckLogged(FeatureTestSupport.id(1), false, nil)) {
            $0.automaticCheckID = nil; $0.dashboardRevision = 2
        }
        await store.receive(.dashboardLoaded(2, DashboardSnapshot()))
        await store.finish()
    }
}
