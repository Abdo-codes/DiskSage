import ComposableArchitecture
import Foundation

extension AppFeature {
    func handleAgentRequest(state: inout State, request: AgentToolRequest) -> EffectOf<Self> {
        switch request.action {
        case .status:
            state.agentToolReply = AgentToolReply(status: AgentToolStatus(busy: state.isBusy,
                awaitingConfirmation: state.pendingDeletionRequest != nil, freeSpaceBytes: client.freeSpace(),
                candidateCount: state.candidates.count, lowRiskCount: state.lowRiskCandidates.count,
                lowRiskBytes: state.lowRiskCandidates.reduce(0) { $0 + $1.size }, lastScanDate: state.lastScanDate,
                cleanupPolicy: client.preferences().agentPolicy.rawValue))
        case .job:
            guard let id = request.requestID, var job = state.agentToolJobs[id] else {
                state.agentToolReply = AgentToolReply(error: "Unknown job. Jobs are retained for this app session only; do not assume cleanup ran.")
                return .none
            }
            if job.phase == .cleaning {
                job.completedCount = state.cleanupCompletedCount
                job.removedEntryCount = state.cleanupRemovedEntryCount
            }
            state.agentToolReply = AgentToolReply(job: job)
        case .scan, .cleanLowRisk:
            guard let id = request.requestID else {
                state.agentToolReply = AgentToolReply(error: "A UUID request_id is required."); return .none
            }
            if let existing = state.agentToolJobs[id] {
                state.agentToolReply = existing.action == request.action ? AgentToolReply(job: existing)
                    : AgentToolReply(error: "request_id belongs to a different action.")
                return .none
            }
            guard !state.isBusy else {
                state.agentToolReply = AgentToolReply(error: "DiskSage is busy. Check status and retry later with the same request_id.")
                return .none
            }
            if request.action == .cleanLowRisk, client.preferences().agentPolicy == .disabled {
                state.agentToolReply = AgentToolReply(error: "Agent cleanup is disabled in DiskSage Settings."); return .none
            }
            let job = AgentToolJob(id: id, action: request.action, startedAt: now, phase: .scanning)
            state.agentToolJobs[id] = job
            state.agentToolJobOrder.append(id)
            state.activeAgentToolJobID = id
            if state.agentToolJobOrder.count > 100,
               let stale = state.agentToolJobOrder.first(where: { $0 != state.activeAgentToolJobID }) {
                state.agentToolJobs[stale] = nil
                state.agentToolJobOrder.removeAll { $0 == stale }
            }
            state.agentToolReply = AgentToolReply(job: job)
            return beginScan(state: &state, purpose: .agent(id))
        }
        return .none
    }

    func finishAgentScan(state: inout State, jobID: UUID) -> EffectOf<Self> {
        guard let job = state.agentToolJobs[jobID], state.activeAgentToolJobID == jobID else { return .none }
        let targets = state.lowRiskCandidates
        let measured = job.action == .scan ? state.candidates : targets
        state.agentToolJobs[jobID]?.candidateCount = measured.count
        state.agentToolJobs[jobID]?.estimatedBytes = measured.reduce(0) { $0 + $1.size }
        guard job.action == .cleanLowRisk, !targets.isEmpty else {
            completeAgentJob(state: &state, id: jobID, phase: .succeeded); return .none
        }
        switch client.preferences().agentPolicy {
        case .disabled: completeAgentJob(state: &state, id: jobID, phase: .cancelled)
        case .confirm:
            state.activityRevision += 1
            state.agentToolJobs[jobID]?.phase = .awaitingConfirmation
            state.pendingDeletionRequest = DeletionRequest(id: uuid(), candidates: targets, trigger: .agent, toolJobID: jobID)
            state.statusMessage = "An agent requested low-risk cleanup. Review to confirm."
        case .automaticLowRisk: return beginCleanup(state: &state, targets: targets, trigger: .agent)
        }
        return .none
    }

    func finishAgentCleanup(state: inout State, jobID: UUID, report: CleanupReport) {
        state.agentToolJobs[jobID]?.removedEntryCount = report.removedEntryCount
        state.agentToolJobs[jobID]?.completedCount = report.items.count
        state.agentToolJobs[jobID]?.deletedCount = report.items.filter(\.succeeded).count
        state.agentToolJobs[jobID]?.failedCount = report.failures.count
        state.agentToolJobs[jobID]?.estimatedRemovedBytes = report.estimatedRemovedBytes
        state.agentToolJobs[jobID]?.actualRecoveredBytes = report.actualRecoveredBytes
        state.agentToolJobs[jobID]?.loggingFailed = report.loggingError != nil
        completeAgentJob(state: &state, id: jobID, phase: report.loggingError != nil || !report.failures.isEmpty ? .warnings : .succeeded)
    }

    func completeAgentJob(state: inout State, id: UUID, phase: AgentToolJob.Phase) {
        state.agentToolJobs[id]?.phase = phase
        state.agentToolJobs[id]?.completedAt = now
        if state.activeAgentToolJobID == id { state.activeAgentToolJobID = nil }
    }
}
