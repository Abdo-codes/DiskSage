import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
struct AgentToolParityTests {
    @Test func filteredReviewSelectionAndRevealUseOnlyCurrentCandidateIDs() async throws {
        let low = FeatureTestSupport.candidate("build-cache"), high = FeatureTestSupport.candidate("archive", risk: .high)
        var state = AppFeature.State(); state.candidates = [low, high]; state.selection = [high.id]
        let revealed = LockIsolated<URL?>(nil)
        let store = ManagementTestSupport.store(state) { $0.management.present = { _, url in revealed.setValue(url) } }
        await store.send(.agentToolRequest(try ManagementTestSupport.request("list_candidates", ["risk": "low", "query": "cache"]))).finish()
        let result = try #require(store.agentToolReply?.data?.object?["candidates"]?.array)
        #expect(result.count == 1 && result[0].object?["id"]?.string == low.id.uuidString)
        #expect(result[0].object?["path"]?.string == low.url.path)
        await store.send(.agentToolRequest(try ManagementTestSupport.request("set_selection", ["mode": "add", "candidate_ids": [low.id.uuidString]]))).finish()
        #expect(store.selection == [low.id, high.id])
        await store.send(.agentToolRequest(try ManagementTestSupport.request("reveal_candidate", ["candidate_id": low.id.uuidString], id: 101))).finish()
        #expect(revealed.value == low.url)
        await store.send(.agentToolRequest(try ManagementTestSupport.request("set_selection", ["mode": "replace", "candidate_ids": []], id: 102))).finish()
        #expect(store.selection.isEmpty)
        await store.send(.agentToolRequest(try ManagementTestSupport.request("set_selection", ["mode": "replace", "candidate_ids": [UUID().uuidString]], id: 103))).finish()
        #expect(store.agentToolReply?.error != nil && store.selection.isEmpty)
    }

    @Test(arguments: ["get_history", "get_logs", "list_models"])
    func asynchronousReadsReturnPollableResultsWithoutClaimingTheCleanupGate(name: String) async throws {
        let expected: ToolValue = .object(["fixture": .string(name)])
        let store = ManagementTestSupport.store { $0.management.read = { _, _ in expected } }
        let request = try ManagementTestSupport.request(name, name == "list_models" ? ["provider": "ollama"] : [:])
        await store.send(.agentToolRequest(request)).finish()
        #expect(!store.isBusy)
        await store.send(.agentToolRequest(.init(action: .job, requestID: request.requestID))).finish()
        #expect(store.agentToolReply?.job?.phase == .succeeded && store.agentToolReply?.job?.result == expected)
        await store.send(.agentToolRequest(request)).finish()
        #expect(store.agentToolReply?.job?.phase == .succeeded)
    }

    @Test func cancellationIsBoundToTheObservedOperationAndDeletionCannotBeCancelled() async throws {
        var state = AppFeature.State(); state.operation = .scanning; state.operationID = FeatureTestSupport.id(5)
        let store = ManagementTestSupport.store(state)
        let wrong = try ManagementTestSupport.request("cancel_operation", ["operation_id": FeatureTestSupport.id(6).uuidString])
        await store.send(.agentToolRequest(wrong)).finish()
        #expect(store.operation == .scanning && store.agentToolReply?.error != nil)
        let matching = try ManagementTestSupport.request("cancel_operation", ["operation_id": FeatureTestSupport.id(5).uuidString], id: 101)
        await store.send(.agentToolRequest(matching)).finish()
        #expect(store.operation == .idle)
        state.operation = .cleaning
        let deleting = ManagementTestSupport.store(state)
        await deleting.send(.agentToolRequest(matching)).finish()
        #expect(deleting.operation == .cleaning && deleting.agentToolReply?.error?.contains("cannot be cancelled") == true)
    }

    @Test func agentsCanDismissButCannotApproveConfirmations() async throws {
        let store = ManagementTestSupport.store()
        let change = try ManagementTestSupport.request("update_settings", ["settings": ["automatic_cleanup_enabled": true]])
        await store.send(.agentToolRequest(change)).finish()
        let dismiss = try ManagementTestSupport.request("dismiss_confirmation", ["confirmation_id": change.requestID!.uuidString], id: 101)
        await store.send(.agentToolRequest(dismiss)).finish()
        #expect(store.pendingManagementApproval == nil && store.agentToolJobs[change.requestID!]?.phase == .cancelled)
        // Local socket callers are validated too; bypassing JSON-RPC grants no approval action.
        let forged = AgentToolRequest(action: .manage, requestID: FeatureTestSupport.id(102), tool: "approve_management",
            arguments: ["request_id": .string(FeatureTestSupport.id(102).uuidString)])
        await store.send(.agentToolRequest(forged)).finish()
        #expect(store.agentToolReply?.error != nil)
    }

    @Test(arguments: ["dashboard", "review", "settings", "schedules", "history", "logs", "agent", "tools", "mcp", "general", "about", "onboarding"])
    func screenRequestsReachTheNativePresentationBoundary(window: String) async throws {
        let screen = LockIsolated<String?>(nil)
        let store = ManagementTestSupport.store { $0.management.present = { value, _ in screen.setValue(value) } }
        await store.send(.agentToolRequest(try ManagementTestSupport.request("open_window", ["window": window]))).finish()
        #expect(screen.value == window)
        #expect(store.agentToolJobs[FeatureTestSupport.id(100)]?.phase == .succeeded)
    }

    @Test func managementWriteFailureBlocksAutomaticSchedulingAndDoesNotReportSuccess() async throws {
        let store = ManagementTestSupport.store(ManagementTestSupport.initial()) {
            $0.diskSage.preferences = { CleanupPreferences(agentPolicy: .automaticLowRisk) }
            $0.management.save = { _, _ in throw FeatureFailure(message: "Disk full") }
        }
        let request = try ManagementTestSupport.request("create_schedule", ManagementTestSupport.createArguments)
        await store.send(.agentToolRequest(request)).finish()
        #expect(store.schedules.isEmpty && store.schedulingBlocked)
        #expect(store.agentToolReply?.error == "Disk full")
        #expect(store.agentToolJobs[request.requestID!]?.phase == .failed)
    }

    @Test func unrelatedReadJobsRemainAvailableWhenScheduleStorageIsCorrupt() async throws {
        let store = ManagementTestSupport.store {
            $0.management.receipt = { _ in throw FeatureFailure(message: "Corrupt schedules") }
            $0.management.read = { _, _ in .object(["history": .array([])]) }
        }
        let request = try ManagementTestSupport.request("get_history")
        await store.send(.agentToolRequest(request)).finish()
        #expect(store.agentToolJobs[request.requestID!]?.phase == .succeeded)
    }

    @Test func dashboardAndReviewExposeTheSameRetainedCleanupFeedbackAsTheUi() async throws {
        let candidate = FeatureTestSupport.candidate()
        let failure = CleanupItemResult(candidate: candidate, removedBytes: 0, errorDescription: "Fixture denied")
        var state = AppFeature.State(); state.candidates = [candidate]; state.cleanupFailures = [failure]
        state.cleanupReport = CleanupReport(items: [failure], freeSpaceBefore: 10, freeSpaceAfter: 20)
        state.lastRecoveredBytes = 10; state.lastAutomaticCleanup = FeatureTestSupport.epoch
        state.automaticCleanupSummary = "Last automatic attempt"
        let store = ManagementTestSupport.store(state)
        await store.send(.agentToolRequest(try ManagementTestSupport.request("get_dashboard"))).finish()
        let dashboard = try #require(store.agentToolReply?.data?.object)
        #expect(dashboard["last_recovered_bytes"]?.integer == 10)
        #expect(dashboard["automatic_cleanup_summary"]?.string == "Last automatic attempt")
        #expect(dashboard["cleanup_report"]?.object?["free_space_after"]?.integer == 20)
        #expect(dashboard["cleanup_report"]?.object?["failed_count"]?.integer == 1)
        await store.send(.agentToolRequest(try ManagementTestSupport.request("list_candidates"))).finish()
        #expect(store.agentToolReply?.data?.object?["candidates"]?.array?.first?.object?["cleanup_error"]?.string == "Fixture denied")
    }

    @Test func retentionNeverEvictsPendingJobsAndRemovesTheirOldRequestCache() async throws {
        var state = AppFeature.State()
        for index in 0..<100 {
            let id = FeatureTestSupport.id(index)
            state.agentToolJobs[id] = AgentToolJob(id: id, action: .manage, startedAt: FeatureTestSupport.epoch,
                phase: index == 0 ? .loading : .succeeded)
            state.agentToolJobOrder.append(id)
            state.managedRequests[id] = .init(action: .manage, requestID: id, tool: "get_history", arguments: [:])
        }
        let store = ManagementTestSupport.store(state) { $0.diskSage.scan = { [] } }
        await store.send(.agentToolRequest(.init(action: .scan, requestID: FeatureTestSupport.id(100)))).finish()
        #expect(store.agentToolJobs.count == 100)
        #expect(store.agentToolJobs[FeatureTestSupport.id(0)]?.phase == .loading)
        #expect(store.agentToolJobs[FeatureTestSupport.id(1)] == nil && store.managedRequests[FeatureTestSupport.id(1)] == nil)
    }
}
