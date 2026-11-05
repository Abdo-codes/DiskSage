import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
struct AgentManagementApprovalTests {
    @Test(arguments: [false, true])
    func settingsCannotGrantAccessBeforeExplicitLocalApproval(approve: Bool) async throws {
        let settings = LockIsolated(ToolSettings.entries.mapValues(\.fallback))
        let store = ManagementTestSupport.store {
            $0.management.settings = { settings.value }
            $0.management.applySettings = { patch in settings.withValue { $0.merge(patch) { $1 } } }
        }
        let request = try ManagementTestSupport.request("update_settings", ["settings": ["agent_cleanup_policy": "automaticLowRisk", "claude_metadata_consent": true]])
        await store.send(.agentToolRequest(request)).finish()
        #expect(settings.value["agent_cleanup_policy"]?.string == "confirm")
        #expect(settings.value["claude_metadata_consent"]?.bool == false)
        #expect(store.pendingManagementApproval?.id == request.requestID)
        await store.send(approve ? .approveManagement(request.requestID!) : .rejectManagement(request.requestID!)).finish()
        #expect(settings.value["agent_cleanup_policy"]?.string == (approve ? "automaticLowRisk" : "confirm"))
        #expect(settings.value["claude_metadata_consent"]?.bool == approve)
        #expect(store.agentToolJobs[request.requestID!]?.phase == (approve ? .succeeded : .cancelled))
    }

    @Test func changedSettingsAreNotOverwrittenByAStaleApproval() async throws {
        let settings = LockIsolated(ToolSettings.entries.mapValues(\.fallback))
        let store = ManagementTestSupport.store { $0.management.settings = { settings.value } }
        let request = try ManagementTestSupport.request("update_settings", ["settings": ["cleanup_threshold_gib": 25]])
        await store.send(.agentToolRequest(request)).finish()
        settings.withValue { $0["cleanup_threshold_gib"] = .integer(30) }
        await store.send(.approveManagement(request.requestID!)).finish()
        #expect(settings.value["cleanup_threshold_gib"]?.integer == 30)
        #expect(store.agentToolJobs[request.requestID!]?.phase == .failed)
    }

    @Test(arguments: [RiskLevel.low, .medium, .high])
    func selectedDeletionAlwaysNeedsHumanConfirmationEvenWithAutomaticAccess(risk: RiskLevel) async throws {
        let candidate = FeatureTestSupport.candidate("fixture", risk: risk)
        var state = AppFeature.State(); state.candidates = [candidate]
        let calls = LockIsolated(0)
        let store = ManagementTestSupport.store(state) {
            $0.diskSage.preferences = { CleanupPreferences(agentPolicy: .automaticLowRisk) }
            $0.diskSage.cleanup = { targets, _, _ in
                calls.withValue { $0 += 1 }
                return CleanupReport(items: targets.map { CleanupItemResult(candidate: $0, removedBytes: $0.size, errorDescription: nil) }, freeSpaceBefore: 0, freeSpaceAfter: 1)
            }
        }
        let request = try ManagementTestSupport.request("delete_candidates", ["candidate_ids": [candidate.id.uuidString]])
        await store.send(.agentToolRequest(request)).finish()
        #expect(calls.value == 0)
        let confirmation = try #require(store.pendingDeletionRequest)
        #expect(confirmation.candidates == [candidate])
        #expect(store.agentToolJobs[request.requestID!]?.phase == .awaitingConfirmation)
        await store.send(.confirmDeletion(confirmation.id)).finish()
        #expect(calls.value == 1 && store.candidates.isEmpty)
        #expect(store.agentToolJobs[request.requestID!]?.phase == .succeeded)
    }

    @Test func adviceUsesConsentAndReturnsAJobWithResults() async throws {
        let candidate = FeatureTestSupport.candidate()
        var initial = AppFeature.State(); initial.candidates = [candidate]
        let settings = LockIsolated(ToolSettings.entries.mapValues(\.fallback)), calls = LockIsolated(0)
        let store = ManagementTestSupport.store(initial) {
            $0.management.settings = { settings.value }
            $0.management.grantConsent = { _ in settings.withValue { $0["claude_metadata_consent"] = .bool(true) } }
            $0.diskSage.advise = { candidates, configuration in
                #expect(configuration.provider == .claude && candidates == [candidate])
                calls.withValue { $0 += 1 }
                return AgentResponse(summary: "Keep this fixture", recommendations: [.init(id: candidate.id, decision: .keep, rationale: "Fixture")])
            }
        }
        let request = try ManagementTestSupport.request("request_advice", ["provider": "claude"])
        await store.send(.agentToolRequest(request)).finish()
        #expect(calls.value == 0 && store.pendingManagementApproval != nil)
        await store.send(.approveManagement(request.requestID!)).finish()
        #expect(calls.value == 1 && store.recommendationSummary == "Keep this fixture")
        #expect(settings.value["claude_metadata_consent"]?.bool == true)
        #expect(store.agentToolJobs[request.requestID!]?.phase == .succeeded)
        #expect(ManagementTestSupport.result(store)["recommendation_count"]?.integer == 1)
    }

    @Test func alteredAdvisorConfigurationCannotReuseOldConsentApproval() async throws {
        let settings = LockIsolated(ToolSettings.entries.mapValues(\.fallback))
        var initial = AppFeature.State(); initial.candidates = [FeatureTestSupport.candidate()]
        let store = ManagementTestSupport.store(initial) { $0.management.settings = { settings.value } }
        let request = try ManagementTestSupport.request("request_advice", ["provider": "claude"])
        await store.send(.agentToolRequest(request)).finish()
        settings.withValue { $0["claude_model"] = .string("changed") }
        await store.send(.approveManagement(request.requestID!)).finish()
        #expect(settings.value["claude_metadata_consent"]?.bool == false)
        #expect(store.agentToolJobs[request.requestID!]?.phase == .failed)
    }
}
