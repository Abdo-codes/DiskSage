import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
struct AppFeatureBuiltInCleanupTests {
    @Test(arguments: AgentProvider.allCases)
    func authorizedProviderRequestUsesTheSharedLowRiskTool(provider: AgentProvider) async {
        let low = FeatureTestSupport.candidate("low")
        let high = FeatureTestSupport.candidate("high", risk: .high)
        let config = AgentConfiguration(provider: provider, allowsCleanupRequests: true)
        let response = AgentResponse(summary: "Request", recommendations: [low, high].map {
            AgentRecommendation(id: $0.id, decision: .delete, rationale: "Generated")
        }, cleanupRequested: true)
        let report = CleanupReport(items: [CleanupItemResult(candidate: low, removedBytes: 4096, errorDescription: nil)],
                                   freeSpaceBefore: 100, freeSpaceAfter: 200)
        let store = FeatureTestSupport.store(.init(candidates: [low, high])) {
            $0.diskSage.preferences = { CleanupPreferences(agentPolicy: .automaticLowRisk, builtInCleanupEnabled: true) }
            $0.diskSage.advise = { targets, configuration in
                #expect(targets == [low, high] && configuration == config); return response
            }
            $0.diskSage.scan = { [low, high] }
            $0.diskSage.cleanup = { targets, trigger, _ in
                #expect(targets == [low] && trigger == .agent); return report
            }
        }
        await store.send(.advisorRequested(config)) {
            $0.activityRevision = 1; $0.operation = .advising; $0.operationID = FeatureTestSupport.id(0)
            $0.statusMessage = "\(provider.title) is reviewing metadata…"
        }
        let jobID = FeatureTestSupport.id(1)
        var job = AgentToolJob(id: jobID, action: .cleanLowRisk, startedAt: FeatureTestSupport.epoch, phase: .scanning)
        await store.receive(.advisorFinished(FeatureTestSupport.id(0), config, .success(response))) {
            $0.selection = [low.id]; $0.recommendations = Dictionary(uniqueKeysWithValues: response.recommendations.map { ($0.id, $0) })
            $0.recommendationSummary = "Request"; $0.operation = .scanning; $0.operationID = FeatureTestSupport.id(2)
            $0.activityRevision = 2; $0.statusMessage = "Scanning generated files…"
            $0.agentToolJobs = [jobID: job]; $0.agentToolJobOrder = [jobID]; $0.activeAgentToolJobID = jobID
            $0.agentToolReply = AgentToolReply(job: job)
        }
        job.phase = .cleaning; job.candidateCount = 1; job.estimatedBytes = 4096
        await store.receive(.scanFinished(FeatureTestSupport.id(2), .agent(jobID), [low, high], 100, DashboardSnapshot())) {
            $0.operation = .cleaning; $0.operationID = FeatureTestSupport.id(3); $0.activityRevision = 3
            $0.recommendations = [:]; $0.recommendationSummary = ""; $0.freeSpaceBytes = 100
            $0.lastScanDate = FeatureTestSupport.epoch; $0.dashboardRevision = 1; $0.agentToolJobs[jobID] = job
            $0.cleanupTotalCount = 1; $0.cleanupCurrentItem = "Preparing cleanup…"; $0.statusMessage = "Deleting approved candidates…"
        }
        job.phase = .succeeded; job.completedAt = FeatureTestSupport.epoch; job.deletedCount = 1; job.completedCount = 1
        job.estimatedRemovedBytes = 4096; job.actualRecoveredBytes = 100
        await store.receive(.cleanupFinished(FeatureTestSupport.id(3), report, DashboardSnapshot())) {
            $0.operation = .idle; $0.operationID = nil; $0.candidates = [high]; $0.selection = []
            $0.cleanupReport = report; $0.lastRecoveredBytes = 100; $0.freeSpaceBytes = 200; $0.dashboardRevision = 2
            $0.activeAgentToolJobID = nil; $0.agentToolJobs[jobID] = job
            $0.statusMessage = "Deleted 1 item(s) · \(Int64(4096).diskSize) estimated"
        }
        await store.finish()
    }

    @Test(arguments: ["notRequested", "configurationOptOut", "settingOptOut", "disabledPolicy", "noLowRiskChoice", "invalidResponse"])
    func hostRejectsUnauthorizedOrInvalidAdviceRequests(scenario: String) async {
        let low = FeatureTestSupport.candidate("low")
        let high = FeatureTestSupport.candidate("high", risk: .high)
        let config = AgentConfiguration(provider: .claude, allowsCleanupRequests: scenario != "configurationOptOut")
        let response = AgentResponse(summary: "Review", recommendations: scenario == "invalidResponse" ? [] : [low, high].map {
            AgentRecommendation(id: $0.id, decision: scenario == "noLowRiskChoice" && $0.risk == .low ? .keep : .delete,
                                rationale: "Review")
        }, cleanupRequested: scenario != "notRequested")
        let store = FeatureTestSupport.store(.init(candidates: [low, high])) {
            $0.diskSage.advise = { _, _ in response }
            $0.diskSage.preferences = {
                CleanupPreferences(agentPolicy: scenario == "disabledPolicy" ? .disabled : .automaticLowRisk,
                                   builtInCleanupEnabled: scenario != "settingOptOut")
            }
        }
        await store.send(.advisorRequested(config)) {
            $0.activityRevision = 1; $0.operation = .advising; $0.operationID = FeatureTestSupport.id(0)
            $0.statusMessage = "Claude is reviewing metadata…"
        }
        if scenario == "invalidResponse" {
            let failure = FeatureFailure(message: AdvisorError.invalidResponse.localizedDescription)
            await store.receive(.advisorFinished(FeatureTestSupport.id(0), config, .failure(failure))) {
                $0.operation = .idle; $0.operationID = nil; $0.errorMessage = failure.message; $0.statusMessage = "Claude review failed"
            }
        } else {
            await store.receive(.advisorFinished(FeatureTestSupport.id(0), config, .success(response))) {
                $0.operation = .idle; $0.operationID = nil
                $0.selection = scenario == "noLowRiskChoice" ? [] : [low.id]
                $0.recommendations = Dictionary(uniqueKeysWithValues: response.recommendations.map { ($0.id, $0) })
                $0.recommendationSummary = "Review"; $0.statusMessage = "Claude review complete"
            }
        }
        await store.finish()
    }

    @Test func builtInRequestsHonorConfirmationPolicy() async {
        let low = FeatureTestSupport.candidate()
        let config = AgentConfiguration(provider: .apple, allowsCleanupRequests: true)
        let response = AgentResponse(summary: "Request", recommendations: [
            AgentRecommendation(id: low.id, decision: .delete, rationale: "Generated")], cleanupRequested: true)
        let store = FeatureTestSupport.store(.init(candidates: [low])) {
            $0.diskSage.advise = { _, _ in response }; $0.diskSage.scan = { [low] }
            $0.diskSage.preferences = { CleanupPreferences(agentPolicy: .confirm, builtInCleanupEnabled: true) }
        }
        await store.send(.advisorRequested(config)) {
            $0.activityRevision = 1; $0.operation = .advising; $0.operationID = FeatureTestSupport.id(0)
            $0.statusMessage = "Apple on-device is reviewing metadata…"
        }
        let jobID = FeatureTestSupport.id(1)
        var job = AgentToolJob(id: jobID, action: .cleanLowRisk, startedAt: FeatureTestSupport.epoch, phase: .scanning)
        await store.receive(.advisorFinished(FeatureTestSupport.id(0), config, .success(response))) {
            $0.selection = [low.id]; $0.recommendations = [low.id: response.recommendations[0]]; $0.recommendationSummary = "Request"
            $0.operation = .scanning; $0.operationID = FeatureTestSupport.id(2); $0.activityRevision = 2
            $0.statusMessage = "Scanning generated files…"; $0.agentToolJobs = [jobID: job]
            $0.agentToolJobOrder = [jobID]; $0.activeAgentToolJobID = jobID; $0.agentToolReply = AgentToolReply(job: job)
        }
        job.phase = .awaitingConfirmation; job.candidateCount = 1; job.estimatedBytes = 4096
        let request = DeletionRequest(id: FeatureTestSupport.id(3), candidates: [low], trigger: .agent, toolJobID: jobID)
        await store.receive(.scanFinished(FeatureTestSupport.id(2), .agent(jobID), [low], 100, DashboardSnapshot())) {
            $0.operation = .idle; $0.operationID = nil; $0.activityRevision = 3
            $0.recommendations = [:]; $0.recommendationSummary = ""; $0.freeSpaceBytes = 100; $0.dashboardRevision = 1
            $0.lastScanDate = FeatureTestSupport.epoch; $0.pendingDeletionRequest = request; $0.agentToolJobs[jobID] = job
            $0.statusMessage = "An agent requested low-risk cleanup. Review to confirm."
        }
        job.phase = .cancelled; job.completedAt = FeatureTestSupport.epoch
        await store.send(.dismissConfirmation) {
            $0.activityRevision = 4; $0.pendingDeletionRequest = nil; $0.activeAgentToolJobID = nil
            $0.agentToolJobs[jobID] = job; $0.statusMessage = "Cleanup cancelled"
        }
        await store.finish()
    }
}
