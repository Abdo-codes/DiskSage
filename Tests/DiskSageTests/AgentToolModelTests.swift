import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
struct AppFeatureToolTests {
    @Test func manualLowRiskActionScansThenRequiresConfirmation() async {
        let low = FeatureTestSupport.candidate("low")
        let high = FeatureTestSupport.candidate("high", risk: .high)
        let store = FeatureTestSupport.store {
            $0.diskSage.scan = { ScanReport(candidates: [low, high]) }
        }
        await store.send(.requestLowRiskCleanup) {
            $0.activityRevision = 1; $0.operation = .scanning; $0.operationID = FeatureTestSupport.id(0)
            $0.statusMessage = "Scanning generated files…"
        }
        let request = DeletionRequest(id: FeatureTestSupport.id(1), candidates: [low])
        await store.receive(.scanFinished(FeatureTestSupport.id(0), .manualLowRisk, [low, high], 100, DashboardSnapshot())) {
            $0.candidates = [low, high]; $0.selection = [low.id]; $0.freeSpaceBytes = 100
            $0.lastScanDate = FeatureTestSupport.epoch; $0.dashboardRevision = 1
            $0.operation = .idle; $0.operationID = nil; $0.activityRevision = 2
            $0.pendingDeletionRequest = request; $0.statusMessage = "Review cleanup before deleting."
        }
        await store.send(.scanRequested(.review))
        await store.send(.deleteApproved([high], .manual))
        await store.send(.dismissConfirmation) {
            $0.activityRevision = 3; $0.pendingDeletionRequest = nil; $0.statusMessage = "Cleanup cancelled"
        }
        await store.finish()
    }

    @Test func agentConfirmationCancellationDeduplicationAndBusyRequestsAreCoordinated() async {
        let low = FeatureTestSupport.candidate()
        let jobID = FeatureTestSupport.id(100)
        let request = AgentToolRequest(action: .cleanLowRisk, requestID: jobID)
        var job = AgentToolJob(id: jobID, action: .cleanLowRisk, startedAt: FeatureTestSupport.epoch, phase: .scanning)
        let store = FeatureTestSupport.store {
            $0.diskSage.scan = { ScanReport(candidates: [low]) }
        }
        await store.send(.agentToolRequest(request)) {
            $0.agentToolJobs = [jobID: job]; $0.agentToolJobOrder = [jobID]; $0.activeAgentToolJobID = jobID
            $0.agentToolReply = AgentToolReply(job: job)
            $0.activityRevision = 1; $0.operation = .scanning; $0.operationID = FeatureTestSupport.id(0)
            $0.statusMessage = "Scanning generated files…"
        }
        job.phase = .awaitingConfirmation; job.candidateCount = 1; job.estimatedBytes = 4096
        let confirmation = DeletionRequest(id: FeatureTestSupport.id(1), candidates: [low], trigger: .agent, toolJobID: jobID)
        await store.receive(.scanFinished(FeatureTestSupport.id(0), .agent(jobID), [low], 100, DashboardSnapshot())) {
            $0.candidates = [low]; $0.selection = [low.id]; $0.freeSpaceBytes = 100
            $0.lastScanDate = FeatureTestSupport.epoch; $0.dashboardRevision = 1
            $0.operation = .idle; $0.operationID = nil; $0.activityRevision = 2
            $0.pendingDeletionRequest = confirmation; $0.agentToolJobs[jobID] = job
            $0.statusMessage = "An agent requested low-risk cleanup. Review to confirm."
        }
        await store.send(.agentToolRequest(request)) { $0.agentToolReply = AgentToolReply(job: job) }
        await store.send(.agentToolRequest(.init(action: .scan, requestID: FeatureTestSupport.id(101)))) {
            $0.agentToolReply = AgentToolReply(error: "DiskSage is busy. Check status and retry later with the same request_id.")
        }
        job.phase = .cancelled; job.completedAt = FeatureTestSupport.epoch
        await store.send(.dismissConfirmation) {
            $0.activityRevision = 3; $0.pendingDeletionRequest = nil; $0.activeAgentToolJobID = nil
            $0.agentToolJobs[jobID] = job; $0.statusMessage = "Cleanup cancelled"
        }
        await store.send(.agentToolRequest(request)) { $0.agentToolReply = AgentToolReply(job: job) }
        await store.send(.confirmDeletion(confirmation.id))
        await store.send(.agentToolRequest(.init(action: .scan, requestID: jobID))) {
            $0.agentToolReply = AgentToolReply(error: "request_id belongs to a different action.")
        }
        await store.finish()
    }

    @Test func policyIsRecheckedAfterScanAndDisabledRequestsNeverStart() async {
        let low = FeatureTestSupport.candidate()
        let values = AsyncStream<[CleanupCandidate]>.makeStream()
        let preferences = LockIsolated(CleanupPreferences(agentPolicy: .automaticLowRisk))
        let jobID = FeatureTestSupport.id(100)
        var job = AgentToolJob(id: jobID, action: .cleanLowRisk, startedAt: FeatureTestSupport.epoch, phase: .scanning)
        let store = FeatureTestSupport.store {
            $0.diskSage.preferences = { preferences.value }
            $0.diskSage.scan = { for await values in values.stream { return ScanReport(candidates: values) }; return ScanReport(candidates: []) }
        }
        await store.send(.agentToolRequest(.init(action: .cleanLowRisk, requestID: jobID))) {
            $0.agentToolJobs = [jobID: job]; $0.agentToolJobOrder = [jobID]; $0.activeAgentToolJobID = jobID
            $0.agentToolReply = AgentToolReply(job: job); $0.activityRevision = 1
            $0.operation = .scanning; $0.operationID = FeatureTestSupport.id(0); $0.statusMessage = "Scanning generated files…"
        }
        preferences.withValue { $0.agentPolicy = .disabled }
        values.continuation.yield([low])
        job.phase = .cancelled; job.completedAt = FeatureTestSupport.epoch; job.candidateCount = 1; job.estimatedBytes = 4096
        await store.receive(.scanFinished(FeatureTestSupport.id(0), .agent(jobID), [low], 100, DashboardSnapshot())) {
            $0.operation = .idle; $0.operationID = nil; $0.candidates = [low]; $0.selection = [low.id]
            $0.freeSpaceBytes = 100; $0.lastScanDate = FeatureTestSupport.epoch; $0.dashboardRevision = 1
            $0.agentToolJobs[jobID] = job; $0.activeAgentToolJobID = nil; $0.statusMessage = "Found 1 candidates"
        }
        await store.send(.agentToolRequest(.init(action: .cleanLowRisk, requestID: FeatureTestSupport.id(101)))) {
            $0.agentToolReply = AgentToolReply(error: "Agent cleanup is disabled in DiskSage Settings.")
        }
        await store.finish()
    }

    @Test func emptyScansAndUnknownJobsNeverClaimDeletion() async {
        let store = FeatureTestSupport.store {
            $0.diskSage.scan = { ScanReport(candidates: []) }
            $0.diskSage.preferences = { CleanupPreferences(agentPolicy: .automaticLowRisk) }
        }
        for (index, action) in [AgentToolRequest.Action.scan, .cleanLowRisk].enumerated() {
            let jobID = FeatureTestSupport.id(100 + index)
            var job = AgentToolJob(id: jobID, action: action, startedAt: FeatureTestSupport.epoch, phase: .scanning)
            await store.send(.agentToolRequest(.init(action: action, requestID: jobID))) {
                $0.agentToolJobs[jobID] = job; $0.agentToolJobOrder.append(jobID); $0.activeAgentToolJobID = jobID
                $0.agentToolReply = AgentToolReply(job: job); $0.activityRevision = index + 1
                $0.operation = .scanning; $0.operationID = FeatureTestSupport.id(index); $0.statusMessage = "Scanning generated files…"
            }
            job.phase = .succeeded; job.completedAt = FeatureTestSupport.epoch
            await store.receive(.scanFinished(FeatureTestSupport.id(index), .agent(jobID), [], 100, DashboardSnapshot())) {
                $0.operation = .idle; $0.operationID = nil; $0.freeSpaceBytes = 100
                $0.lastScanDate = FeatureTestSupport.epoch; $0.dashboardRevision = index + 1
                $0.agentToolJobs[jobID] = job; $0.activeAgentToolJobID = nil; $0.statusMessage = "Nothing reclaimable found"
            }
        }
        await store.send(.agentToolRequest(.init(action: .job, requestID: FeatureTestSupport.id(999)))) {
            $0.agentToolReply = AgentToolReply(error: "Unknown job. Jobs are retained for this app session only; do not assume cleanup ran.")
        }
        await store.send(.agentToolRequest(.init(action: .cleanLowRisk))) {
            $0.agentToolReply = AgentToolReply(error: "A UUID request_id is required.")
        }
        await store.finish()
    }
}
