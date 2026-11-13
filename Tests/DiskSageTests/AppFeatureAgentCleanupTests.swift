import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
struct AppFeatureAgentCleanupTests {
    @Test func automaticAgentCleanupScansFreshExcludesSensitiveTargetsAndSanitizesFailures() async throws {
        let low = FeatureTestSupport.candidate("low")
        let high = FeatureTestSupport.candidate("high", risk: .high)
        let medium = FeatureTestSupport.candidate("medium", risk: .medium)
        let stale = FeatureTestSupport.candidate("stale")
        let jobID = FeatureTestSupport.id(100)
        let failure = CleanupItemResult(candidate: low, removedBytes: 0, errorDescription: "/private/secret-project failed")
        let report = CleanupReport(items: [failure], freeSpaceBefore: 100, freeSpaceAfter: 100, loggingError: "/private/secret-log unavailable")
        let store = FeatureTestSupport.store(.init(candidates: [stale], lastScanDate: FeatureTestSupport.epoch)) {
            $0.diskSage.preferences = { CleanupPreferences(agentPolicy: .automaticLowRisk) }
            $0.diskSage.scan = { ScanReport(candidates: [low, medium, high]) }
            $0.diskSage.cleanup = { targets, trigger, _ in
                #expect(targets == [low] && trigger == .agent); return report
            }
        }
        var job = AgentToolJob(id: jobID, action: .cleanLowRisk, startedAt: FeatureTestSupport.epoch, phase: .scanning)
        await store.send(.agentToolRequest(.init(action: .cleanLowRisk, requestID: jobID))) {
            $0.agentToolJobs = [jobID: job]; $0.agentToolJobOrder = [jobID]; $0.activeAgentToolJobID = jobID
            $0.agentToolReply = AgentToolReply(job: job); $0.activityRevision = 1
            $0.operation = .scanning; $0.operationID = FeatureTestSupport.id(0); $0.statusMessage = "Scanning generated files…"
        }
        job.phase = .cleaning; job.candidateCount = 1; job.estimatedBytes = 4096
        await store.receive(.scanFinished(FeatureTestSupport.id(0), .agent(jobID), [low, medium, high], 100, DashboardSnapshot())) {
            $0.candidates = [low, medium, high]; $0.selection = [low.id]; $0.freeSpaceBytes = 100; $0.dashboardRevision = 1
            $0.operation = .cleaning; $0.operationID = FeatureTestSupport.id(1); $0.activityRevision = 2
            $0.cleanupTotalCount = 1; $0.cleanupCurrentItem = "Preparing cleanup…"; $0.statusMessage = "Deleting approved candidates…"
            $0.agentToolJobs[jobID] = job
        }
        job.phase = .warnings; job.completedAt = FeatureTestSupport.epoch; job.failedCount = 1; job.completedCount = 1; job.loggingFailed = true
        await store.receive(.cleanupFinished(FeatureTestSupport.id(1), report, DashboardSnapshot())) {
            $0.operation = .idle; $0.operationID = nil; $0.cleanupFailures = [failure]; $0.cleanupReport = report
            $0.errorMessage = report.loggingError; $0.dashboardRevision = 2; $0.statusMessage = "Cleanup stopped; see details below"
            $0.agentToolJobs[jobID] = job; $0.activeAgentToolJobID = nil
        }
        await store.send(.agentToolRequest(.init(action: .job, requestID: jobID))) { $0.agentToolReply = AgentToolReply(job: job) }
        let output = String(decoding: try JSONEncoder().encode(store.state.agentToolReply), as: UTF8.self)
        #expect(!output.contains("secret") && !output.contains("/fixture"))
        await store.send(.agentToolRequest(.init(action: .cleanLowRisk, requestID: jobID)))
        await store.finish()
    }
    @Test func agentApprovalUsesItsSnapshotAndDuplicateApprovalsCannotStartAnotherDeletion() async {
        let low = FeatureTestSupport.candidate("low")
        let high = FeatureTestSupport.candidate("high", risk: .high)
        let finish = AsyncStream<Bool>.makeStream()
        let jobID = FeatureTestSupport.id(100)
        var job = AgentToolJob(id: jobID, action: .cleanLowRisk, startedAt: FeatureTestSupport.epoch, phase: .scanning)
        let report = CleanupReport(items: [CleanupItemResult(candidate: low, removedBytes: 4096, errorDescription: nil)],
                                   freeSpaceBefore: 100, freeSpaceAfter: 200, removedEntryCount: 3)
        let store = FeatureTestSupport.store {
            $0.diskSage.scan = { ScanReport(candidates: [low, high]) }
            $0.diskSage.cleanup = { targets, trigger, _ in
                #expect(targets == [low] && trigger == .agent)
                for await _ in finish.stream { break }
                return report
            }
        }
        await store.send(.agentToolRequest(.init(action: .cleanLowRisk, requestID: jobID))) {
            $0.agentToolJobs = [jobID: job]; $0.agentToolJobOrder = [jobID]; $0.activeAgentToolJobID = jobID
            $0.agentToolReply = AgentToolReply(job: job); $0.activityRevision = 1
            $0.operation = .scanning; $0.operationID = FeatureTestSupport.id(0); $0.statusMessage = "Scanning generated files…"
        }
        job.phase = .awaitingConfirmation; job.candidateCount = 1; job.estimatedBytes = 4096
        let request = DeletionRequest(id: FeatureTestSupport.id(1), candidates: [low], trigger: .agent, toolJobID: jobID)
        await store.receive(.scanFinished(FeatureTestSupport.id(0), .agent(jobID), [low, high], 100, DashboardSnapshot())) {
            $0.candidates = [low, high]; $0.selection = [low.id]; $0.freeSpaceBytes = 100
            $0.lastScanDate = FeatureTestSupport.epoch; $0.dashboardRevision = 1
            $0.operation = .idle; $0.operationID = nil; $0.activityRevision = 2
            $0.pendingDeletionRequest = request; $0.agentToolJobs[jobID] = job
            $0.statusMessage = "An agent requested low-risk cleanup. Review to confirm."
        }
        await store.send(.selectionChanged([high.id])) { $0.selection = [high.id] }
        job.phase = .cleaning
        await store.send(.confirmDeletion(request.id)) {
            $0.pendingDeletionRequest = nil; $0.operation = .cleaning; $0.operationID = FeatureTestSupport.id(2)
            $0.activityRevision = 3; $0.cleanupTotalCount = 1; $0.cleanupCurrentItem = "Preparing cleanup…"
            $0.statusMessage = "Deleting approved candidates…"; $0.agentToolJobs[jobID] = job
        }
        await store.send(.confirmDeletion(request.id))
        await store.send(.dismissConfirmation)
        await store.send(.agentToolRequest(.init(action: .cleanLowRisk, requestID: jobID))) {
            $0.agentToolReply = AgentToolReply(job: job)
        }
        finish.continuation.yield(true)
        job.phase = .succeeded; job.completedAt = FeatureTestSupport.epoch; job.completedCount = 1; job.deletedCount = 1
        job.removedEntryCount = 3; job.estimatedRemovedBytes = 4096; job.actualRecoveredBytes = 100
        await store.receive(.cleanupFinished(FeatureTestSupport.id(2), report, DashboardSnapshot())) {
            $0.operation = .idle; $0.operationID = nil; $0.candidates = [high]; $0.cleanupReport = report
            $0.freeSpaceBytes = 200; $0.lastRecoveredBytes = 100; $0.cleanupRemovedEntryCount = 3; $0.dashboardRevision = 2
            $0.statusMessage = "Deleted 1 item(s) · \(Int64(4096).diskSize) estimated"
            $0.activeAgentToolJobID = nil; $0.agentToolJobs[jobID] = job
        }
        await store.finish()
    }

    @Test func disablingAgentCleanupWhileAwaitingApprovalRevokesTheRequest() async {
        let low = FeatureTestSupport.candidate()
        let jobID = FeatureTestSupport.id(100)
        var job = AgentToolJob(id: jobID, action: .cleanLowRisk, startedAt: FeatureTestSupport.epoch, phase: .awaitingConfirmation)
        let request = DeletionRequest(id: FeatureTestSupport.id(200), candidates: [low], trigger: .agent, toolJobID: jobID)
        let store = FeatureTestSupport.store(.init(candidates: [low], pendingDeletionRequest: request,
            agentToolJobs: [jobID: job], agentToolJobOrder: [jobID], activeAgentToolJobID: jobID)) {
            $0.diskSage.preferences = { CleanupPreferences(agentPolicy: .disabled) }
        }
        job.phase = .cancelled; job.completedAt = FeatureTestSupport.epoch
        await store.send(.confirmDeletion(request.id)) {
            $0.pendingDeletionRequest = nil; $0.activityRevision = 1; $0.activeAgentToolJobID = nil
            $0.agentToolJobs[jobID] = job; $0.statusMessage = "Agent cleanup is disabled."
        }
        await store.finish()
    }

}
