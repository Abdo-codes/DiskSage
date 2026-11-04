import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
struct AppFeatureAdvisorTests {
    @Test func recommendationsPreserveIDsAndNeverSelectSensitiveItems() async {
        let low = FeatureTestSupport.candidate("low")
        let high = FeatureTestSupport.candidate("high", risk: .high)
        let medium = FeatureTestSupport.candidate("medium", risk: .medium)
        let targets = [low, medium, high]
        let config = AgentConfiguration(provider: .claude, model: "sonnet")
        let response = AgentResponse(summary: "Done", recommendations: targets.map {
            AgentRecommendation(id: $0.id, decision: .delete, rationale: "Generated")
        })
        let store = FeatureTestSupport.store(.init(candidates: targets)) {
            $0.diskSage.advise = { received, configuration in
                #expect(received == targets && configuration == config)
                return response
            }
        }
        await store.send(.advisorRequested(config)) {
            $0.activityRevision = 1; $0.operation = .advising; $0.operationID = FeatureTestSupport.id(0)
            $0.statusMessage = "Claude is reviewing metadata…"
        }
        await store.receive(.advisorFinished(FeatureTestSupport.id(0), config, .success(response))) {
            $0.operation = .idle; $0.operationID = nil
            $0.selection = [low.id]
            $0.recommendations = Dictionary(uniqueKeysWithValues: response.recommendations.map { ($0.id, $0) })
            $0.recommendationSummary = "Done"; $0.statusMessage = "Claude review complete"
        }
        await store.finish()
    }

    @Test func invalidProviderOutputPreservesSelectionAndCannotRequestCleanup() async {
        let low = FeatureTestSupport.candidate()
        let config = AgentConfiguration(provider: .apple, allowsCleanupRequests: true)
        let failure = FeatureFailure(message: AdvisorError.invalidResponse.localizedDescription)
        let store = FeatureTestSupport.store(.init(candidates: [low], selection: [low.id])) {
            $0.diskSage.advise = { _, _ in AgentResponse(summary: "Invalid", recommendations: [], cleanupRequested: true) }
        }
        await store.send(.advisorRequested(config)) {
            $0.activityRevision = 1; $0.operation = .advising; $0.operationID = FeatureTestSupport.id(0)
            $0.statusMessage = "Apple on-device is reviewing metadata…"
        }
        await store.receive(.advisorFinished(FeatureTestSupport.id(0), config, .failure(failure))) {
            $0.operation = .idle; $0.operationID = nil; $0.errorMessage = failure.message
            $0.statusMessage = "Apple on-device review failed"
        }
        await store.finish()
    }

    @Test func cancellationEndsTheRealEffectAndLateAdviceCannotResetAnotherOperation() async {
        let low = FeatureTestSupport.candidate()
        let advice = AsyncStream<AgentResponse>.makeStream()
        let scan = AsyncStream<[CleanupCandidate]>.makeStream()
        let cancelled = LockIsolated(false)
        advice.continuation.onTermination = { termination in
            if case .cancelled = termination { cancelled.setValue(true) }
        }
        let config = AgentConfiguration(provider: .claude)
        let store = FeatureTestSupport.store(.init(candidates: [low])) {
            $0.diskSage.advise = { _, _ in
                for await response in advice.stream { return response }
                throw CancellationError()
            }
            $0.diskSage.scan = { for await value in scan.stream { return value }; return [] }
        }
        let adviceTask = await store.send(.advisorRequested(config)) {
            $0.activityRevision = 1; $0.operation = .advising; $0.operationID = FeatureTestSupport.id(0)
            $0.statusMessage = "Claude is reviewing metadata…"
        }
        await store.send(.cancelOperation) {
            $0.activityRevision = 2; $0.operation = .idle; $0.operationID = nil; $0.statusMessage = "Operation cancelled"
        }
        await adviceTask.finish()
        #expect(cancelled.value)
        await store.send(.scanRequested(.review)) {
            $0.activityRevision = 3; $0.operation = .scanning; $0.operationID = FeatureTestSupport.id(1)
            $0.statusMessage = "Scanning generated files…"
        }
        await store.send(.advisorFinished(FeatureTestSupport.id(0), config,
            .success(AgentResponse(summary: "Stale", recommendations: []))))
        scan.continuation.yield([])
        await store.receive(.scanFinished(FeatureTestSupport.id(1), .review, [], 100, DashboardSnapshot())) {
            $0.operation = .idle; $0.operationID = nil; $0.candidates = []; $0.lastScanDate = FeatureTestSupport.epoch
            $0.freeSpaceBytes = 100; $0.dashboardRevision = 1; $0.statusMessage = "Nothing reclaimable found"
        }
        await store.finish()
    }
}
