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

    @Test(arguments: [false, true])
    func projectCacheRulesUpdateRequiresApprovalAndSavesOnApprove(approve: Bool) async throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let extra = try f.folder("Work")
        let rulesURL = f.base.appending(path: ".config/disksage/rules.json")

        let store = ManagementTestSupport.store {
            $0.management.projectCacheRulesHome = { f.base }
            $0.management.projectCacheRulesPath = { rulesURL.path }
            $0.management.loadProjectCacheRulesSnapshot = { try ProjectCacheRulesLoader.loadConfigSnapshot(from: rulesURL) }
            $0.management.saveProjectCacheRules = { config, expected in
                try ProjectCacheRulesLoader.save(config, to: rulesURL, home: f.base, expectedExistingData: .some(expected))
            }
            $0.management.readProjectCacheRules = { ToolProjectCacheRules.snapshotValue(configURL: rulesURL, home: f.base) }
        }

        let request = try ManagementTestSupport.request("update_project_cache_rules", [
            "rules": [
                "quiet_hours": 48,
                "extra_roots": ["~/Work"],
                "names": [".cache-x"],
                "skip": ["vendor"],
            ],
        ])
        await store.send(.agentToolRequest(request)).finish()
        #expect(!FileManager.default.fileExists(atPath: rulesURL.path))
        #expect(store.pendingManagementApproval?.id == request.requestID)
        #expect(store.agentToolJobs[request.requestID!]?.phase == .awaitingConfirmation)

        await store.send(approve ? .approveManagement(request.requestID!) : .rejectManagement(request.requestID!)).finish()
        #expect(store.agentToolJobs[request.requestID!]?.phase == (approve ? .succeeded : .cancelled))
        if approve {
            let loaded = try ProjectCacheRulesLoader.loadConfig(from: rulesURL)
            #expect(loaded.quietHours == 48)
            #expect(loaded.extraRoots == ["~/Work"])
            #expect(loaded.names == [".cache-x"])
            #expect(loaded.skip == ["vendor"])
            let snapshot = ManagementTestSupport.result(store)
            #expect(snapshot["exists"]?.bool == true)
            let effectiveRoots = snapshot["effective"]?.object?["extra_roots"]?.array?.compactMap(\.string) ?? []
            #expect(effectiveRoots == [CleanupPath.fileURL(extra).path])
        } else {
            #expect(!FileManager.default.fileExists(atPath: rulesURL.path))
        }
    }

    @Test func projectCacheRulesRejectsStaleConflictAndInvalidRules() async throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let rulesURL = f.base.appending(path: ".config/disksage/rules.json")
        _ = try ProjectCacheRulesLoader.save(.init(quietHours: 36), to: rulesURL, home: f.base)

        let store = ManagementTestSupport.store {
            $0.management.projectCacheRulesHome = { f.base }
            $0.management.projectCacheRulesPath = { rulesURL.path }
            $0.management.loadProjectCacheRulesSnapshot = { try ProjectCacheRulesLoader.loadConfigSnapshot(from: rulesURL) }
            $0.management.saveProjectCacheRules = { config, expected in
                try ProjectCacheRulesLoader.save(config, to: rulesURL, home: f.base, expectedExistingData: .some(expected))
            }
            $0.management.readProjectCacheRules = { ToolProjectCacheRules.snapshotValue(configURL: rulesURL, home: f.base) }
        }

        // Invalid rules are rejected immediately without awaiting approval.
        let invalidRulePatches: [[String: Any]] = [
            ["extra_roots": ["~/Library/Caches"]],
            ["names": [".git"]],
            ["skip": ["a/b"]],
            ["reset": true, "quiet_hours": 12],
        ]
        for (offset, badRules) in invalidRulePatches.enumerated() {
            let bad = try ManagementTestSupport.request("update_project_cache_rules", ["rules": badRules], id: 200 + offset)
            await store.send(.agentToolRequest(bad)).finish()
            #expect(store.pendingManagementApproval == nil)
            #expect(store.agentToolReply?.error != nil)
        }

        // External write invalidates a pending approval.
        let update = try ManagementTestSupport.request("update_project_cache_rules", ["rules": ["quiet_hours": 72]], id: 300)
        await store.send(.agentToolRequest(update)).finish()
        #expect(store.pendingManagementApproval?.id == update.requestID)
        _ = try ProjectCacheRulesLoader.save(.init(skip: ["archive"], quietHours: 96), to: rulesURL, home: f.base)
        await store.send(.approveManagement(update.requestID!)).finish()
        #expect(store.agentToolJobs[update.requestID!]?.phase == .failed)
        let preserved = try ProjectCacheRulesLoader.loadConfig(from: rulesURL)
        #expect(preserved.quietHours == 96 && preserved.skip == ["archive"])
    }
}
