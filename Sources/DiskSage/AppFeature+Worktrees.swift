import ComposableArchitecture
import Foundation

extension AppFeature {
    func reduceWorktrees(state: inout State, action: WorktreesFeature.Action) -> EffectOf<Self> {
        let externalBusy = state.operation != .idle || state.pendingDeletionRequest != nil || state.pendingManagementApproval != nil
        switch action {
        case .load, .loadRepository, .addRoot, .removeRoot, .setIntegration, .preview, .reviewUnused, .setProtected, .confirm:
            guard !externalBusy else { state.worktrees.error = "Wait for the current cleanup or confirmation."; return .none }
        case let .loaded(id, _):
            guard state.worktrees.loadID == id else { return .none }
        default: break
        }
        let pending: WorktreePreview?
        if case .removed = action { pending = state.worktrees.activeRemoval }
        else { pending = state.worktrees.pending }
        if case .confirm = action, pending?.toolRequestID != nil, client.preferences().agentPolicy == .disabled {
            state.worktrees.error = "Agent cleanup access was disabled. Dismiss this request."
            return .none
        }
        let effect = WorktreesFeature().reduceAction(state: &state.worktrees, action: action).map { Action.worktrees($0) }
        if state.worktrees.isBusy { state.activityRevision += 1 }
        if state.worktrees.pending != nil && !state.worktrees.removing {
            state.statusMessage = "Review the worktree request in Cleanup Review."
        }
        if case .dismiss = action, pending != nil { state.statusMessage = "Worktree review cancelled." }
        if case .load = action, state.worktrees.loading { state.statusMessage = "Inspecting Git worktrees…" }
        if case .loadRepository = action, state.worktrees.loading { state.statusMessage = "Inspecting the requested Git repository…" }
        if case .confirm = action, state.worktrees.removing {
            state.statusMessage = "Removing approved Git checkouts…"
            state.cleanupCompletedCount = 0; state.cleanupTotalCount = pending?.items.count ?? 0
            state.cleanupRemovedEntryCount = 0; state.cleanupActiveItems = [:]
            state.cleanupCurrentItem = "Git removal; remaining rows can be cancelled in Worktrees review."
            state.cleanupReport = nil
        }
        if let id = pending?.toolRequestID {
            switch action {
            case .confirm:
                if pending?.protectionChange == false, state.worktrees.pending == nil {
                    finishWorktreeTool(state: &state, id: id, phase: .succeeded, result: .object(["protected": .bool(false)]))
                } else if state.worktrees.removing { state.agentToolJobs[id]?.phase = .cleaning }
            case .dismiss: finishWorktreeTool(state: &state, id: id, phase: .cancelled, result: .object(["message": .string("Declined in DiskSage; no checkout removed.")]))
            case let .removed(results):
                state.agentToolJobs[id]?.completedCount = results.count
                state.agentToolJobs[id]?.deletedCount = results.filter(\.succeeded).count
                state.agentToolJobs[id]?.failedCount = results.filter { !$0.succeeded }.count
                let success = results.count == pending?.items.count && results.allSatisfy(\.succeeded)
                finishWorktreeTool(state: &state, id: id, phase: success ? .succeeded : .warnings,
                    result: (try? .encode(results)) ?? .null)
            default: break
            }
        }
        if case .cancelLoad = action {
            for id in state.agentToolJobOrder where state.managedRequests[id]?.tool == "refresh_worktrees" && state.agentToolJobs[id]?.phase == .loading {
                finishWorktreeTool(state: &state, id: id, phase: .cancelled, result: .object(["message": .string("Inspection cancelled; no checkout was removed.")]))
            }
        }
        if case let .loaded(_, result) = action {
            let checked = (try? result.get().items.count) ?? 0
            state.statusMessage = state.worktrees.error == nil ? "Git worktrees checked: \(checked)." : "Worktree inspection needs attention."
            for id in state.agentToolJobOrder where state.managedRequests[id]?.tool == "refresh_worktrees" && state.agentToolJobs[id]?.phase == .loading {
                finishWorktreeTool(state: &state, id: id, phase: state.worktrees.error == nil ? .succeeded : .failed,
                    result: .object(["count": .integer(checked), "warnings": (try? .encode(state.worktrees.warnings)) ?? .null,
                        "error": state.worktrees.error.map(ToolValue.string) ?? .null]))
            }
        }
        if case let .removed(results) = action {
            state.statusMessage = "Git worktrees: \(results.filter(\.succeeded).count) removed; \(results.filter { !$0.succeeded }.count) need attention."
            state.cleanupCompletedCount = results.count
            let removed = results.filter(\.succeeded).map(\.path)
            let stale = Set(state.candidates.filter { candidate in removed.contains { WorktreePathGuard.contains($0, candidate.url.path) } }.map(\.id))
            state.candidates.removeAll { stale.contains($0.id) }; state.selection.subtract(stale)
            for id in stale { state.recommendations[id] = nil }
            return .merge(effect, .send(.refreshDashboard))
        }
        return effect
    }

    func handleWorktreeTool(state: inout State, request: AgentToolRequest) -> EffectOf<Self> {
        do {
            let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request.arguments ?? [:])) as! [String: Any]
            guard let name = request.tool, try MCPManagementSchema.command(name: name, arguments: raw) == request else { throw FeatureFailure(message: "Invalid worktree request.") }
            let args = request.arguments ?? [:]
            if name == "list_worktrees" {
                guard state.worktrees.loaded else { throw FeatureFailure(message: "Use refresh_worktrees first. Approve folders in Cleanup Review → Git Worktrees.") }
                state.agentToolReply = AgentToolReply(data: try ToolPage.make(state.worktrees.reviewItems.map { try WorktreeToolPresentation.summary($0) }, key: "worktrees",
                    offset: args["offset"]?.integer ?? 0, limit: args["limit"]?.integer ?? 20)); return .none
            }
            if name == "inspect_worktree" {
                let item = try worktreeItem(args, state: state)
                state.agentToolReply = AgentToolReply(data: try WorktreeToolPresentation.detail(item, args: args)); return .none
            }
            if name == "preview_worktree_removal" || name == "preview_unused_worktrees" {
                guard !state.isBusy else { throw FeatureFailure(message: "DiskSage is busy.") }
                guard state.worktrees.loaded else { throw FeatureFailure(message: "Refresh worktrees before previewing cleanup.") }
                let preview: WorktreePreview
                if name == "preview_unused_worktrees" {
                    preview = try WorktreeQuickCleanup.preview(state.worktrees.reviewItems, id: uuid())
                } else {
                    let ids = args["worktree_ids"]?.array?.compactMap(\.string) ?? []
                    let items = state.worktrees.reviewItems.filter { ids.contains($0.id) }.map(WorktreeQuickCleanup.compactForReview)
                    guard !ids.isEmpty, items.count == ids.count, items.allSatisfy(\.canRequestRemoval) else { throw FeatureFailure(message: "Unknown, duplicate or blocked worktrees. Refresh and inspect them first.") }
                    guard args["allow_discard"] == .bool(true) || items.allSatisfy(\.canRemove) else {
                        throw FeatureFailure(message: "These checkouts contain data requiring destructive review. Inspect removal_warnings, then preview with allow_discard=true to request native approval. Nothing is approved by this flag.")
                    }
                    try WorktreeQuickCleanup.validateSize(items)
                    preview = WorktreePreview(id: uuid(), items: items)
                }
                let reply = try WorktreeToolPresentation.preview(preview)
                if state.worktrees.toolPreviews.count >= 10 { state.worktrees.toolPreviews = [:] }
                state.worktrees.toolPreviews[preview.id] = preview
                state.agentToolReply = AgentToolReply(data: reply); return .none
            }
            guard let id = request.requestID else { throw FeatureFailure(message: "A UUID request_id is required.") }
            if let job = state.agentToolJobs[id] {
                guard state.managedRequests[id] == request else { throw FeatureFailure(message: "request_id belongs to another request.") }
                state.agentToolReply = AgentToolReply(job: job); return .none
            }
            if let receipt = try worktreeClient.receipt(id) {
                guard receipt.request == request else { throw FeatureFailure(message: "request_id belongs to different arguments.") }
                state.agentToolReply = AgentToolReply(data: receipt.result); return .none
            }
            guard try management.receipt(id) == nil, !state.isBusy else { throw FeatureFailure(message: "DiskSage is busy or request_id is already used.") }
            if name != "refresh_worktrees", client.preferences().agentPolicy == .disabled { throw FeatureFailure(message: "Agent cleanup access is disabled.") }
            // Persist acceptance before exposing approval. A restart can never blindly repeat this request.
            try worktreeClient.saveReceipt(WorktreeReceipt(request: request, result: .object(["phase": .string("cancelled"),
                "message": .string("Request accepted, but completion is unconfirmed. If DiskSage restarted, inspect the checkout and History; use a new UUID after fresh review.")])))
            trackManagement(state: &state, request: request)
            var effect: EffectOf<Self> = .none
            if name == "refresh_worktrees" {
                effect = reduceWorktrees(state: &state, action: args["repository_root"]?.string.map(WorktreesFeature.Action.loadRepository) ?? .load)
            }
            else if name == "remove_worktrees" {
                guard let token = args["snapshot_token"]?.string.flatMap(UUID.init(uuidString:)),
                      var preview = state.worktrees.toolPreviews[token], preview.items.allSatisfy(\.canRequestRemoval) else {
                    throw FeatureFailure(message: "Unknown or expired preview. Refresh and preview again.")
                }
                preview.toolRequestID = id; state.worktrees.pending = preview
                state.statusMessage = "An agent requested checkout removal. Review Git Worktrees to confirm."
                state.agentToolJobs[id]?.candidateCount = preview.items.count
                state.agentToolJobs[id]?.estimatedBytes = preview.estimatedBytes
                state.worktrees.toolPreviews[token] = nil
                state.agentToolJobs[id]?.phase = .awaitingConfirmation
                effect = showWorktreeApproval()
            } else {
                let item = try worktreeItem(args, state: state)
                let protected = args["protected"] == .bool(true)
                if protected {
                    effect = reduceWorktrees(state: &state, action: .setProtected(item.id, true))
                    guard state.worktrees.error == nil else { throw FeatureFailure(message: state.worktrees.error!) }
                    finishWorktreeTool(state: &state, id: id, phase: .succeeded, result: .object(["protected": .bool(true)]))
                } else {
                    state.worktrees.pending = WorktreePreview(id: uuid(), items: [item], toolRequestID: id, protectionChange: false)
                    state.agentToolJobs[id]?.phase = .awaitingConfirmation
                    effect = showWorktreeApproval()
                }
            }
            state.agentToolReply = AgentToolReply(job: state.agentToolJobs[id]!)
            return effect
        } catch {
            if let id = request.requestID, state.managedRequests[id] == request {
                finishWorktreeTool(state: &state, id: id, phase: .failed, result: .object(["error": .string(error.localizedDescription)]))
            }
            state.agentToolReply = AgentToolReply(error: error.localizedDescription); return .none
        }
    }
    func worktreeItem(_ args: [String: ToolValue], state: State) throws -> WorktreeInspection {
        guard let id = args["worktree_id"]?.string, let item = state.worktrees.reviewItems.first(where: { $0.id == id }) else {
            throw FeatureFailure(message: "Unknown worktree; refresh the inventory first.")
        }
        return item
    }
    func finishWorktreeTool(state: inout State, id: UUID, phase: AgentToolJob.Phase, result: ToolValue) {
        state.agentToolJobs[id]?.result = result
        completeAgentJob(state: &state, id: id, phase: phase)
        if let request = state.managedRequests[id] {
            do { try worktreeClient.saveReceipt(WorktreeReceipt(request: request, result: .object(["phase": .string(phase.rawValue), "result": result]))) }
            catch { state.worktrees.error = "Result receipt could not be saved: \(error.localizedDescription)" }
        }
    }
    func showWorktreeApproval() -> EffectOf<Self> {
        .run { [management] _ in try await management.present("worktrees", nil) }
    }
}
