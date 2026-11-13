import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

/// A pending deletion keeps the app busy. These tests prove that it blocks the Worktrees section
/// and that it can always be dismissed, so the root review sheet is never a dead end.
@MainActor
struct DeletionConfirmationReachabilityTests {
    @Test func pendingDeletionBlocksWorktreesUntilItIsDismissed() async {
        let candidate = FeatureTestSupport.candidate()
        var state = AppFeature.State(); state.candidates = [candidate]
        state.pendingDeletionRequest = DeletionRequest(id: FeatureTestSupport.id(1), candidates: [candidate])
        let store = ManagementTestSupport.store(state)
        #expect(store.isBusy)
        await store.send(.worktrees(.reviewUnused)).finish()
        #expect(store.worktrees.error == "Wait for the current cleanup or confirmation.")
        await store.send(.dismissConfirmation).finish()
        #expect(store.pendingDeletionRequest == nil && !store.isBusy)
        #expect(store.statusMessage == "Cleanup cancelled")
    }

    @Test func agentDeletionIsVisibleAndDismissableThroughMCP() async throws {
        let candidate = FeatureTestSupport.candidate()
        var state = AppFeature.State(); state.candidates = [candidate]
        let store = ManagementTestSupport.store(state) {
            $0.diskSage.preferences = { CleanupPreferences(agentPolicy: .confirm) }
        }
        let request = try ManagementTestSupport.request("delete_candidates", ["candidate_ids": [candidate.id.uuidString]])
        await store.send(.agentToolRequest(request)).finish()
        let pending = try #require(store.pendingDeletionRequest)
        #expect(pending.trigger == .agent && store.isBusy)
        await store.send(.agentToolRequest(try ManagementTestSupport.request("get_dashboard", id: 101))).finish()
        let confirmation = store.agentToolReply?.data?.object?["confirmation"]?.object
        #expect(confirmation?["id"]?.string == pending.id.uuidString)
        let dismiss = try ManagementTestSupport.request("dismiss_confirmation", ["confirmation_id": pending.id.uuidString], id: 102)
        await store.send(.agentToolRequest(dismiss)).finish()
        #expect(store.pendingDeletionRequest == nil && !store.isBusy)
        #expect(store.agentToolJobs[request.requestID!]?.phase == .cancelled)
    }
}
