import ComposableArchitecture
import Foundation

extension AppFeature {
    func reduceCleanup(state: inout State, action: Action) -> EffectOf<Self> {
        switch action {
        case let .requestDeletion(targets):
            guard !state.isBusy, !targets.isEmpty else { return .none }
            state.activityRevision += 1
            state.pendingDeletionRequest = DeletionRequest(id: uuid(), candidates: targets)
            state.statusMessage = "Review cleanup before deleting."
        case .requestLowRiskCleanup:
            guard !state.isBusy else { return .none }
            if state.lastScanDate == nil { return beginScan(state: &state, purpose: .manualLowRisk) }
            return requestLowRiskConfirmation(state: &state)
        case let .confirmDeletion(id):
            guard let request = state.pendingDeletionRequest, request.id == id else { return .none }
            if let jobID = request.toolJobID, client.preferences().agentPolicy == .disabled {
                state.pendingDeletionRequest = nil
                state.activityRevision += 1
                completeAgentJob(state: &state, id: jobID, phase: .cancelled)
                state.statusMessage = "Agent cleanup is disabled."
                return .none
            }
            // Claim the root operation before clearing presentation state, in one reducer transaction.
            let effect = beginCleanup(state: &state, targets: request.candidates, trigger: request.trigger)
            state.pendingDeletionRequest = nil
            return effect
        case .dismissConfirmation:
            guard let request = state.pendingDeletionRequest else { return .none }
            state.pendingDeletionRequest = nil
            state.activityRevision += 1
            if let jobID = request.toolJobID { completeAgentJob(state: &state, id: jobID, phase: .cancelled) }
            state.statusMessage = "Cleanup cancelled"
        case let .deleteApproved(targets, trigger):
            guard !state.isBusy, !targets.isEmpty else { return .none }
            return beginCleanup(state: &state, targets: targets, trigger: trigger)
        case let .cleanupProgress(id, progress):
            guard state.operationID == id, state.isCleaning else { return .none }
            state.apply(progress)
        case let .cleanupFinished(id, report, dashboard):
            guard state.operationID == id, state.isCleaning else { return .none }
            let automatic = state.operation == .automaticCleanup
            state.reconcile(report)
            state.dashboardRevision += 1
            state.apply(dashboard)
            state.operation = .idle
            state.operationID = nil
            if automatic {
                state.lastAutomaticCleanup = now
                state.automaticCleanupSummary = state.statusMessage
            }
            if let jobID = state.activeAgentToolJobID { finishAgentCleanup(state: &state, jobID: jobID, report: report) }
        default: break
        }
        return .none
    }

    func requestLowRiskConfirmation(state: inout State) -> EffectOf<Self> {
        guard !state.lowRiskCandidates.isEmpty else {
            state.statusMessage = "No low-risk items to clean"
            return .none
        }
        return reduceCleanup(state: &state, action: .requestDeletion(state.lowRiskCandidates))
    }

    func beginCleanup(state: inout State, targets: [CleanupCandidate], trigger: CleanupTrigger) -> EffectOf<Self> {
        let id = uuid()
        state.activityRevision += 1
        state.operationID = id
        state.operation = trigger == .automatic ? .automaticCleanup : .cleaning
        state.errorMessage = nil
        state.cleanupFailures = []
        state.cleanupReport = nil
        state.cleanupRemovedEntryCount = 0
        state.cleanupCompletedCount = 0
        state.cleanupTotalCount = targets.count
        state.cleanupActiveItems = [:]
        state.cleanupCurrentItem = "Preparing cleanup…"
        state.statusMessage = "Deleting approved candidates…"
        if let job = state.activeAgentToolJobID { state.agentToolJobs[job]?.phase = .cleaning }
        // Intentionally no cancellation ID: deletion belongs to the persistent application store.
        return .run { [client] send in
            let report = await client.cleanup(targets, trigger) { progress in await send(.cleanupProgress(id, progress)) }
            let dashboard = await client.dashboard()
            await send(.cleanupFinished(id, report, dashboard))
        }
    }
}

extension AppFeature.State {
    mutating func apply(_ progress: CleanupProgress) {
        switch progress {
        case let .entriesRemoved(count): cleanupRemovedEntryCount = count
        case let .started(candidate, completed, total):
            cleanupActiveItems[candidate.id] = candidate.name
            cleanupCompletedCount = completed
            cleanupTotalCount = total
            updateCleanupActivity()
        case let .finished(result, completed, total):
            cleanupActiveItems[result.candidate.id] = nil
            cleanupCompletedCount = completed
            cleanupTotalCount = total
            updateCleanupActivity()
            if result.succeeded { removeCandidates([result.candidate.id]) }
            else { cleanupFailures.append(result) }
        }
    }

    mutating func reconcile(_ report: CleanupReport) {
        cleanupActiveItems = [:]
        removeCandidates(Set(report.items.filter(\.succeeded).map(\.candidate.id)))
        cleanupFailures = report.failures
        cleanupReport = report
        cleanupRemovedEntryCount = report.removedEntryCount
        lastRecoveredBytes = report.actualRecoveredBytes
        freeSpaceBytes = report.freeSpaceAfter
        errorMessage = report.loggingError
        statusMessage = CleanupOutcome(report: report).title
    }

    private mutating func removeCandidates(_ ids: Set<UUID>) {
        candidates.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        for id in ids { recommendations[id] = nil }
    }

    private mutating func updateCleanupActivity() {
        let names = cleanupActiveItems.values.sorted()
        cleanupCurrentItem = names.isEmpty ? "Finishing cleanup…" : names.prefix(2).joined(separator: ", ")
        if names.count > 2 { cleanupCurrentItem += " and \(names.count - 2) more" }
    }
}
