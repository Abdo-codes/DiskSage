import ComposableArchitecture
import Foundation

extension AppFeature {
    func reduceOperations(state: inout State, action: Action) -> EffectOf<Self> {
        switch action {
        case let .scanRequested(purpose):
            guard !state.isBusy else { return .none }
            return beginScan(state: &state, purpose: purpose)
        case let .scanFinished(id, purpose, results, available, dashboard):
            guard state.operationID == id, state.isScanning else { return .none }
            state.candidates = results
            if purpose == .automatic { state.selection.formIntersection(Set(results.map(\.id))) }
            else { state.selection = Set(results.filter { $0.risk == .low }.map(\.id)) }
            state.recommendations = [:]
            state.recommendationSummary = ""
            state.freeSpaceBytes = available
            state.lastScanDate = now
            state.dashboardRevision += 1
            state.apply(dashboard)
            state.operation = .idle
            state.operationID = nil
            state.statusMessage = results.isEmpty ? "Nothing reclaimable found" : "Found \(results.count) candidates"
            switch purpose {
            case .review: return .none
            case .manualLowRisk: return requestLowRiskConfirmation(state: &state)
            case let .agent(job): return finishAgentScan(state: &state, jobID: job)
            case .automatic: return finishAutomaticScan(state: &state)
            }
        case let .advisorRequested(configuration):
            guard !state.isBusy, !state.candidates.isEmpty else { return .none }
            let id = uuid()
            let snapshot = state.candidates
            state.activityRevision += 1
            state.operation = .advising
            state.operationID = id
            state.errorMessage = nil
            state.statusMessage = "\(configuration.provider.title) is reviewing metadata…"
            return .run { [client] send in
                let result: Result<AgentResponse, FeatureFailure>
                do {
                    let response = try await client.advise(snapshot, configuration)
                    try AdvisorContract.validate(response, expectedIDs: Set(snapshot.map(\.id)))
                    result = .success(response)
                } catch { result = .failure(FeatureFailure(message: error.localizedDescription)) }
                guard !Task.isCancelled else { return }
                await send(.advisorFinished(id, configuration, result))
            }.cancellable(id: CancelID.advisor)
        case let .advisorFinished(id, configuration, result):
            guard state.operationID == id, state.operation == .advising else { return .none }
            state.operation = .idle
            state.operationID = nil
            switch result {
            case let .failure(error):
                state.errorMessage = error.message
                state.statusMessage = "\(configuration.provider.title) review failed"
                if let job = state.activeAgentToolJobID, state.agentToolJobs[job]?.phase == .advising {
                    state.agentToolJobs[job]?.result = .object(["error": .string(error.message)])
                    completeAgentJob(state: &state, id: job, phase: .failed)
                }
            case let .success(response):
                state.recommendations = Dictionary(uniqueKeysWithValues: response.recommendations.map { ($0.id, $0) })
                state.recommendationSummary = response.summary
                let choices = state.candidates.filter { $0.risk == .low && state.recommendations[$0.id]?.decision == .delete }
                state.selection = Set(choices.map(\.id))
                state.statusMessage = "\(configuration.provider.title) review complete"
                if let job = state.activeAgentToolJobID, state.agentToolJobs[job]?.phase == .advising {
                    state.agentToolJobs[job]?.result = .object(["summary": .string(response.summary),
                        "recommendation_count": .integer(response.recommendations.count), "cleanup_requested": .bool(response.cleanupRequested == true)])
                    completeAgentJob(state: &state, id: job, phase: .succeeded)
                }
                let preferences = client.preferences()
                if configuration.allowsCleanupRequests, response.cleanupRequested == true, !choices.isEmpty,
                   preferences.builtInCleanupEnabled, preferences.agentPolicy != .disabled {
                    return handleAgentRequest(state: &state, request: AgentToolRequest(action: .cleanLowRisk, requestID: uuid()))
                }
            }
            return .none
        case .cancelOperation:
            guard !state.isCleaning else { return .none }
            if state.pendingDeletionRequest != nil { return reduceCleanup(state: &state, action: .dismissConfirmation) }
            state.activityRevision += 1
            state.operation = .idle
            state.operationID = nil
            state.statusMessage = "Operation cancelled"
            if state.activeSchedule != nil {
                finishScheduleAttempt(state: &state, message: "Scheduled cleanup cancelled.")
            }
            if let job = state.activeAgentToolJobID { completeAgentJob(state: &state, id: job, phase: .cancelled) }
            return .merge(.cancel(id: CancelID.scan), .cancel(id: CancelID.advisor))
        default: return .none
        }
    }

    func finishAutomaticScan(state: inout State) -> EffectOf<Self> {
        let preferences = client.preferences()
        guard preferences.automaticEnabled else {
            state.statusMessage = "Automatic cleanup skipped: disabled in Settings."
            return .none
        }
        guard state.freeSpaceBytes <= Int64(preferences.thresholdGiB) * 1_024 * 1_024 * 1_024 else {
            state.statusMessage = "Automatic cleanup skipped: free space is above the \(preferences.thresholdGiB) GiB threshold."
            return .none
        }
        guard !state.lowRiskCandidates.isEmpty else {
            state.statusMessage = "No low-risk items to clean automatically."
            return .none
        }
        return beginCleanup(state: &state, targets: state.lowRiskCandidates, trigger: .automatic)
    }

    func beginScan(state: inout State, purpose: ScanPurpose, reservedID: UUID? = nil) -> EffectOf<Self> {
        let id = reservedID ?? uuid()
        if purpose == .automatic { state.automaticRetryAfter = now.addingTimeInterval(Self.automaticRetryInterval) }
        state.activityRevision += 1
        state.operationID = id
        state.operation = purpose == .automatic ? .automaticScan : .scanning
        state.cleanupReport = nil
        state.cleanupFailures = []
        state.errorMessage = nil
        state.statusMessage = purpose == .automatic ? "Low disk space detected; scanning low-risk items…" : "Scanning generated files…"
        return .run { [client] send in
            let results = await client.scan()
            guard !Task.isCancelled else { return }
            let dashboard = await client.dashboard()
            guard !Task.isCancelled else { return }
            let available = await client.capacity()
            guard !Task.isCancelled else { return }
            await send(.scanFinished(id, purpose, results, available, dashboard))
        }.cancellable(id: CancelID.scan)
    }
}
