import ComposableArchitecture
import Foundation

extension AppFeature {
    func manageControls(state: inout State, request: AgentToolRequest) throws -> EffectOf<Self> {
        let args = request.arguments ?? [:], id = request.requestID!
        switch request.tool {
        case "set_selection":
            guard !state.isBusy else { throw FeatureFailure(message: "DiskSage is busy.") }
            let ids = try managedCandidateIDs(args, state: state)
            switch args["mode"]?.string {
            case "add": state.selection.formUnion(ids)
            case "remove": state.selection.subtract(ids)
            default: state.selection = ids
            }
            finishManagedValue(state: &state, id: id, value: try .encode(state.selection.sorted { $0.uuidString < $1.uuidString }))
        case "cancel_operation":
            if state.worktrees.loading, let target = args["operation_id"]?.string.flatMap(UUID.init(uuidString:)), state.worktrees.loadID == target {
                let effect = reduceWorktrees(state: &state, action: .cancelLoad)
                finishManagedValue(state: &state, id: id, value: .object(["inspection_cancelled": .bool(true)]))
                return effect
            }
            if state.worktrees.removing, let target = args["operation_id"]?.string.flatMap(UUID.init(uuidString:)), state.worktrees.activeRemoval?.id == target {
                let effect = reduceWorktrees(state: &state, action: .cancelQueued)
                finishManagedValue(state: &state, id: id, value: .object(["queued_removals_cancelled": .bool(true), "running_removal_continues": .bool(true)]))
                return effect
            }
            guard !state.isCleaning else { throw FeatureFailure(message: "Deletion has already started and cannot be cancelled.") }
            guard state.operationID == args["operation_id"]?.string.flatMap(UUID.init(uuidString:)) else {
                throw FeatureFailure(message: "The operation changed. Read get_dashboard before cancelling.")
            }
            let effect = reduceOperations(state: &state, action: .cancelOperation)
            finishManagedValue(state: &state, id: id, value: .object(["cancelled": .bool(true)]))
            return effect
        case "dismiss_confirmation":
            let target = args["confirmation_id"]?.string.flatMap(UUID.init(uuidString:))
            let effect: EffectOf<Self>
            if let target, state.pendingManagementApproval?.id == target {
                effect = reduceManagement(state: &state, action: .rejectManagement(target))
            } else if state.pendingDeletionRequest?.id == target, target != nil {
                effect = reduceCleanup(state: &state, action: .dismissConfirmation)
            } else if state.worktrees.pending?.id == target, target != nil {
                effect = reduceWorktrees(state: &state, action: .dismiss)
            } else { throw FeatureFailure(message: "The confirmation changed. Read get_dashboard again.") }
            finishManagedValue(state: &state, id: id, value: .object(["cancelled": .bool(true)]))
            return effect
        case "open_window", "reveal_candidate":
            let path: URL?
            if request.tool == "reveal_candidate" {
                guard let target = args["candidate_id"]?.string.flatMap(UUID.init(uuidString:)),
                      let candidate = state.candidates.first(where: { $0.id == target }) else {
                    throw FeatureFailure(message: "Unknown candidate. Scan or list candidates again.")
                }
                path = candidate.url
            } else { path = nil }
            let screen = args["window"]?.string ?? "reveal"
            return .run { [management] send in
                do {
                    try await management.present(screen, path)
                    await send(.managementFinished(id, .success(.object(["opened": .string(screen)]))))
                } catch { await send(.managementFinished(id, .failure(FeatureFailure(message: error.localizedDescription)))) }
            }
        case "quit_app":
            guard !state.isCleaning else { throw FeatureFailure(message: "Wait until deletion finishes before quitting.") }
            finishManagedValue(state: &state, id: id, value: .object(["quit_requested": .bool(true),
                "message": .string("DiskSage will quit unless cleanup starts first. MCP and schedule checks stop while the app is closed.")]))
            return .run { [management] _ in try await management.present("quit", nil) }
        default: throw FeatureFailure(message: "Unknown management tool.")
        }
        return .none
    }

    func managedCandidateIDs(_ args: [String: ToolValue], state: State) throws -> Set<UUID> {
        let values = args["candidate_ids"]?.array ?? []
        let ids = Set(values.compactMap { $0.string.flatMap(UUID.init(uuidString:)) })
        guard ids.count == values.count, ids.isSubset(of: Set(state.candidates.map(\.id))) else {
            throw FeatureFailure(message: "Unknown or duplicate candidate IDs. Scan and list candidates again.")
        }
        return ids
    }
    func requestManagedDeletion(state: inout State, request: AgentToolRequest) throws -> EffectOf<Self> {
        guard !state.isBusy else { throw FeatureFailure(message: "DiskSage is busy.") }
        guard client.preferences().agentPolicy != .disabled else { throw FeatureFailure(message: "Agent cleanup is disabled.") }
        let ids = try managedCandidateIDs(request.arguments ?? [:], state: state)
        guard !ids.isEmpty else { throw FeatureFailure(message: "Choose at least one candidate.") }
        let targets = state.candidates.filter { ids.contains($0.id) }, id = request.requestID!
        state.agentToolJobs[id]?.phase = .awaitingConfirmation
        state.agentToolJobs[id]?.candidateCount = targets.count
        state.agentToolJobs[id]?.estimatedBytes = targets.reduce(0) { $0 + $1.size }
        state.activeAgentToolJobID = id
        state.activityRevision += 1
        state.pendingDeletionRequest = DeletionRequest(id: uuid(), candidates: targets, trigger: .agent, toolJobID: id)
        state.statusMessage = "An agent requested selected-item deletion. Review every path to confirm."
        return .none
    }

    func requestManagedAdvice(state: inout State, request: AgentToolRequest, approved: Bool) throws -> EffectOf<Self> {
        guard !state.isBusy, !state.candidates.isEmpty else { throw FeatureFailure(message: "Scan first and wait for the current operation to finish.") }
        let provider = AgentProvider(rawValue: request.arguments?["provider"]?.string ?? "")!
        let (configuration, consent) = ToolSettings.configuration(provider, values: management.settings())
        if !consent && !approved {
            return try requestManagementApproval(state: &state, request: request,
                title: "Share cleanup metadata through \(provider.title)?",
                details: "Provider: \(provider.title)\nModel: \(configuration.model.isEmpty ? "Provider default" : configuration.model)\nExecutable: \(configuration.executablePath.isEmpty ? "Detect automatically" : configuration.executablePath)\n\nShares only categories, sizes, risk, generic reasons and random IDs. Paths and project names are excluded. Providers and Ollama cloud models may process this metadata remotely. Consent remains enabled for this provider until revoked in Settings.", configuration: configuration)
        }
        if approved { management.grantConsent(provider) }
        state.agentToolJobs[request.requestID!]?.phase = .advising
        state.activeAgentToolJobID = request.requestID!
        return reduceOperations(state: &state, action: .advisorRequested(configuration))
    }
}
