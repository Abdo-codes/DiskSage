import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
struct WorktreesFeatureTests {
    static func item() -> WorktreeInspection {
        WorktreeInspection(worktree: GitWorktree(path: "/fixture/feature", commonDirectory: "/fixture/main/.git", branch: "refs/heads/feature",
            head: "123", locked: false, missing: false, main: false), retainedRefs: ["refs/heads/feature": "123"], fingerprint: "evidence")
    }
    @Test func manualRemovalHasNoDefaultSelectionAndBlocksOtherCleanupUntilFinished() async throws {
        let item = Self.item(), calls = LockIsolated(0)
        var initial = AppFeature.State(); initial.worktrees.items = [item]; initial.worktrees.loaded = true
        let store = ManagementTestSupport.store(initial) {
            $0.worktrees.remove = { preview in
                calls.withValue { $0 += 1 }
                return preview.items.map { WorktreeResult(id: $0.id, path: $0.worktree.path, succeeded: true, message: "removed") }
            }
        }
        #expect(store.worktrees.selection.isEmpty)
        await store.send(.worktrees(.select([item.id]))).finish()
        await store.send(.worktrees(.preview)).finish()
        #expect(store.isBusy && calls.value == 0)
        await store.send(.requestLowRiskCleanup).finish()
        #expect(store.pendingDeletionRequest == nil)
        let id = try #require(store.worktrees.pending?.id)
        await store.send(.worktrees(.confirm(UUID()))).finish()
        #expect(calls.value == 0)
        await store.send(.worktrees(.confirm(id))).finish()
        #expect(calls.value == 1 && !store.isBusy && store.worktrees.pending == nil)
    }

    @Test(arguments: [false, true])
    func agentsAlwaysNeedNativeApproval(approve: Bool) async throws {
        let item = Self.item(), calls = LockIsolated(0), receipts = LockIsolated<[WorktreeReceipt]>([])
        var initial = AppFeature.State(); initial.worktrees.items = [item]; initial.worktrees.loaded = true
        let store = ManagementTestSupport.store(initial) {
            $0.diskSage.preferences = { CleanupPreferences(agentPolicy: .automaticLowRisk) }
            $0.worktrees.saveReceipt = { receipt in receipts.withValue { $0.append(receipt) } }
            $0.worktrees.remove = { _ in calls.withValue { $0 += 1 }; return [WorktreeResult(id: item.id, path: item.worktree.path, succeeded: true, message: "removed")] }
        }
        await store.send(.agentToolRequest(try ManagementTestSupport.request("preview_worktree_removal", ["worktree_ids": [item.id]]))).finish()
        let token = try #require(store.agentToolReply?.data?.object?["snapshot_token"]?.string)
        let request = try ManagementTestSupport.request("remove_worktrees", ["snapshot_token": token])
        await store.send(.agentToolRequest(request)).finish()
        #expect(calls.value == 0 && store.agentToolJobs[request.requestID!]?.phase == .awaitingConfirmation)
        #expect(!receipts.value.isEmpty)
        await store.send(.agentToolRequest(request)).finish()
        let pending = try #require(store.worktrees.pending)
        await store.send(.worktrees(approve ? .confirm(pending.id) : .dismiss)).finish()
        #expect(calls.value == (approve ? 1 : 0))
        #expect(store.agentToolJobs[request.requestID!]?.phase == (approve ? .succeeded : .cancelled))
    }

    @Test func staleTokensAndForgedPathsCannotBypassPolicy() async throws {
        let store = ManagementTestSupport.store()
        let request = try ManagementTestSupport.request("remove_worktrees", ["snapshot_token": UUID().uuidString])
        await store.send(.agentToolRequest(request)).finish()
        #expect(store.worktrees.pending == nil && store.agentToolReply?.error != nil)
        #expect(throws: MCPServer.MCPError.self) {
            try MCPManagementSchema.command(name: "remove_worktrees", arguments: ["request_id": UUID().uuidString, "snapshot_token": UUID().uuidString, "path": "/anything", "force": true])
        }
    }

    @Test func durablePendingReceiptCannotBeResumedAfterRestart() async throws {
        let request = try ManagementTestSupport.request("remove_worktrees", ["snapshot_token": UUID().uuidString])
        let receipt = WorktreeReceipt(request: request, result: .object(["phase": .string("cancelled"), "message": .string("completion unconfirmed")]))
        let calls = LockIsolated(0)
        let store = ManagementTestSupport.store {
            $0.worktrees.receipt = { _ in receipt }
            $0.worktrees.remove = { _ in calls.withValue { $0 += 1 }; return [] }
        }
        await store.send(.agentToolRequest(request)).finish()
        #expect(calls.value == 0 && store.worktrees.pending == nil)
        await store.send(.agentToolRequest(.init(action: .job, requestID: request.requestID))).finish()
        #expect(store.agentToolReply?.job?.phase == .cancelled)
    }

    @Test func unprotectRequiresConfirmationAndBusyRootRejectsWorktreeCommands() async throws {
        let item = Self.item(), saved = LockIsolated(0)
        var initial = AppFeature.State(); initial.worktrees.items = [item]; initial.operation = .scanning
        let store = ManagementTestSupport.store(initial) { $0.worktrees.saveConfiguration = { _ in saved.withValue { $0 += 1 } } }
        await store.send(.worktrees(.setProtected(item.id, false))).finish()
        #expect(store.worktrees.pending == nil && saved.value == 0)
        store.send(.cancelOperation)
        await store.send(.worktrees(.setProtected(item.id, false))).finish()
        #expect(store.worktrees.pending?.protectionChange == false && saved.value == 0)
        await store.send(.worktrees(.dismiss)).finish()
        #expect(saved.value == 0)
    }
    @Test func worktreeRemovalReconcilesNestedCacheCandidates() async {
        let item = Self.item()
        var initial = AppFeature.State()
        initial.candidates = [CleanupCandidate(url: URL(fileURLWithPath: item.worktree.path + "/.build"), name: "Build", category: .build,
            size: 123, risk: .low, reason: "Generated")]
        initial.selection = Set(initial.candidates.map(\.id))
        let store = ManagementTestSupport.store(initial)
        await store.send(.worktrees(.removed([WorktreeResult(id: item.id, path: item.worktree.path, succeeded: true, message: "Removed")]))).finish()
        #expect(store.candidates.isEmpty && store.selection.isEmpty)
    }

    @Test func queuedCancellationDoesNotDismissAnActiveRemoval() async {
        let calls = LockIsolated<[UUID]>([])
        let preview = WorktreePreview(items: [Self.item()])
        var initial = AppFeature.State(); initial.worktrees.activeRemoval = preview; initial.worktrees.removing = true
        let store = ManagementTestSupport.store(initial) { $0.worktrees.cancel = { id in calls.withValue { $0.append(id) } } }
        await store.send(.worktrees(.dismiss)).finish()
        #expect(store.worktrees.activeRemoval == preview && store.worktrees.pending == nil && store.isCleaning)
        await store.send(.worktrees(.cancelQueued)).finish()
        #expect(calls.value == [preview.id] && store.worktrees.cancelling && store.worktrees.activeRemoval == preview)
    }

    @Test func cancelledInspectionIgnoresLateEvidence() async {
        let id = UUID()
        var initial = AppFeature.State(); initial.worktrees.loading = true; initial.worktrees.loadID = id
        let store = ManagementTestSupport.store(initial)
        await store.send(.worktrees(.cancelLoad)).finish()
        await store.send(.worktrees(.configurationLoaded(id, WorktreeConfiguration(roots: ["/stale"])))).finish()
        await store.send(.worktrees(.loaded(id, .success(WorktreeInventory(items: [Self.item()]))))).finish()
        #expect(!store.worktrees.loading && store.worktrees.loadID == nil && store.worktrees.items.isEmpty && store.worktrees.configuration.roots.isEmpty)
    }

    @Test func worktreeJobsNeverReportProgressFromAnEarlierCacheCleanup() async throws {
        let id = UUID()
        let request = AgentToolRequest(action: .manage, requestID: id, tool: "remove_worktrees", arguments: [:])
        var initial = AppFeature.State()
        initial.cleanupCompletedCount = 42; initial.cleanupRemovedEntryCount = 1000
        initial.worktrees.removing = true
        initial.worktrees.activeRemoval = WorktreePreview(items: [Self.item()])
        initial.managedRequests[id] = request
        initial.agentToolJobs[id] = AgentToolJob(id: id, action: .manage, startedAt: Date(), phase: .cleaning, candidateCount: 1)
        let store = ManagementTestSupport.store(initial)
        await store.send(.agentToolRequest(.init(action: .job, requestID: id))).finish()
        let job = try #require(store.agentToolReply?.job)
        #expect(job.completedCount == 0 && job.removedEntryCount == 0 && job.candidateCount == 1)
        #expect(store.dashboardPresentation.primaryAction == .cleanupProgress)
        #expect(!store.dashboardPresentation.canCleanNow)
    }

}
