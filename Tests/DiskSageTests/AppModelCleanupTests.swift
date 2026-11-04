import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
struct AppFeatureCleanupTests {
    @Test func partialProgressRemovesSuccessesRetainsFailuresAndCannotBeCancelledByDismissal() async {
        let good = FeatureTestSupport.candidate("good")
        let bad = FeatureTestSupport.candidate("bad")
        let remaining = FeatureTestSupport.candidate("remaining")
        let success = CleanupItemResult(candidate: good, removedBytes: good.size, errorDescription: nil)
        let failure = CleanupItemResult(candidate: bad, removedBytes: 0, errorDescription: "Permission denied")
        let progress = AsyncStream<CleanupProgress>.makeStream()
        let report = CleanupReport(items: [success, failure], freeSpaceBefore: 100, freeSpaceAfter: 200, removedEntryCount: 256)
        let store = FeatureTestSupport.store(.init(candidates: [good, bad, remaining], selection: [good.id, bad.id])) {
            $0.diskSage.cleanup = { targets, trigger, callback in
                #expect(targets == [good, bad] && trigger == .manual)
                for await update in progress.stream { await callback(update) }
                return report
            }
        }
        await store.send(.deleteApproved([good, bad], .manual)) {
            $0.activityRevision = 1; $0.operation = .cleaning; $0.operationID = FeatureTestSupport.id(0)
            $0.cleanupTotalCount = 2; $0.cleanupCurrentItem = "Preparing cleanup…"
            $0.statusMessage = "Deleting approved candidates…"
        }
        progress.continuation.yield(.started(good, completed: 0, total: 2))
        await store.receive(.cleanupProgress(FeatureTestSupport.id(0), .started(good, completed: 0, total: 2))) {
            $0.cleanupActiveItems = [good.id: "good"]; $0.cleanupCurrentItem = "good"
        }
        progress.continuation.yield(.finished(success, completed: 1, total: 2))
        await store.receive(.cleanupProgress(FeatureTestSupport.id(0), .finished(success, completed: 1, total: 2))) {
            $0.cleanupActiveItems = [:]; $0.cleanupCurrentItem = "Finishing cleanup…"; $0.cleanupCompletedCount = 1
            $0.candidates = [bad, remaining]; $0.selection = [bad.id]
        }
        progress.continuation.yield(.entriesRemoved(128))
        await store.receive(.cleanupProgress(FeatureTestSupport.id(0), .entriesRemoved(128))) { $0.cleanupRemovedEntryCount = 128 }
        await store.send(.cancelOperation)
        await store.send(.dismissConfirmation)
        await store.send(.scanRequested(.review))
        await store.send(.deleteApproved([remaining], .manual))
        progress.continuation.yield(.finished(failure, completed: 2, total: 2))
        await store.receive(.cleanupProgress(FeatureTestSupport.id(0), .finished(failure, completed: 2, total: 2))) {
            $0.cleanupCompletedCount = 2; $0.cleanupFailures = [failure]
        }
        progress.continuation.finish()
        await store.receive(.cleanupFinished(FeatureTestSupport.id(0), report, DashboardSnapshot())) {
            $0.operation = .idle; $0.operationID = nil; $0.cleanupReport = report
            $0.cleanupRemovedEntryCount = 256; $0.lastRecoveredBytes = 100; $0.freeSpaceBytes = 200
            $0.dashboardRevision = 1; $0.statusMessage = "Cleanup finished: 1 deleted, 1 failed"
        }
        await store.finish()
    }

    @Test func confirmationUsesItsImmutableSnapshotAndReconcilesMissingProgressAndLoggingFailure() async {
        let approved = FeatureTestSupport.candidate("approved")
        let other = FeatureTestSupport.candidate("other")
        let report = CleanupReport(items: [CleanupItemResult(candidate: approved, removedBytes: 4096, errorDescription: nil)],
                                   freeSpaceBefore: 100, freeSpaceAfter: 100, loggingError: "Log unavailable")
        let finish = AsyncStream<Bool>.makeStream()
        let store = FeatureTestSupport.store(.init(candidates: [approved, other], selection: [approved.id])) {
            $0.diskSage.cleanup = { targets, trigger, _ in
                #expect(targets == [approved] && trigger == .manual)
                for await _ in finish.stream { break }
                return report
            }
        }
        let request = DeletionRequest(id: FeatureTestSupport.id(0), candidates: [approved])
        await store.send(.requestDeletion([approved])) {
            $0.activityRevision = 1; $0.pendingDeletionRequest = request; $0.statusMessage = "Review cleanup before deleting."
        }
        await store.send(.selectionChanged([other.id])) { $0.selection = [other.id] }
        await store.send(.scanRequested(.review))
        await store.send(.confirmDeletion(request.id)) {
            $0.activityRevision = 2; $0.pendingDeletionRequest = nil; $0.operation = .cleaning
            $0.operationID = FeatureTestSupport.id(1); $0.cleanupTotalCount = 1
            $0.cleanupCurrentItem = "Preparing cleanup…"; $0.statusMessage = "Deleting approved candidates…"
        }
        await store.send(.confirmDeletion(request.id))
        await store.send(.dismissConfirmation)
        finish.continuation.yield(true)
        await store.receive(.cleanupFinished(FeatureTestSupport.id(1), report, DashboardSnapshot())) {
            $0.operation = .idle; $0.operationID = nil; $0.candidates = [other]; $0.cleanupReport = report
            $0.errorMessage = "Log unavailable"; $0.freeSpaceBytes = 100; $0.dashboardRevision = 1
            $0.statusMessage = "Cleanup stopped; see details below"
        }
        await store.finish()
    }

    @Test func tracksAllParallelTargetsAndRejectsStaleProgress() async {
        let a = FeatureTestSupport.candidate("a")
        let b = FeatureTestSupport.candidate("b")
        let updates = AsyncStream<CleanupProgress>.makeStream()
        let report = CleanupReport(items: [], freeSpaceBefore: 0, freeSpaceAfter: 0)
        let store = FeatureTestSupport.store {
            $0.diskSage.cleanup = { _, _, progress in for await update in updates.stream { await progress(update) }; return report }
        }
        await store.send(.deleteApproved([a, b], .manual)) {
            $0.activityRevision = 1; $0.operation = .cleaning; $0.operationID = FeatureTestSupport.id(0)
            $0.cleanupTotalCount = 2; $0.cleanupCurrentItem = "Preparing cleanup…"; $0.statusMessage = "Deleting approved candidates…"
        }
        for target in [a, b] {
            updates.continuation.yield(.started(target, completed: 0, total: 2))
            await store.receive(.cleanupProgress(FeatureTestSupport.id(0), .started(target, completed: 0, total: 2))) {
                $0.cleanupActiveItems[target.id] = target.name
                $0.cleanupCurrentItem = target == a ? "a" : "a, b"
            }
        }
        await store.send(.cleanupProgress(FeatureTestSupport.id(99), .entriesRemoved(999)))
        updates.continuation.finish()
        await store.receive(.cleanupFinished(FeatureTestSupport.id(0), report, DashboardSnapshot())) {
            $0.operation = .idle; $0.operationID = nil; $0.cleanupActiveItems = [:]; $0.cleanupReport = report
            $0.dashboardRevision = 1; $0.statusMessage = "Deleted 0 item(s) · \(Int64(0).diskSize) estimated"
        }
        await store.finish()
    }
}
