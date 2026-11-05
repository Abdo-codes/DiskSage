import ComposableArchitecture
import Foundation

extension AppFeature {
    func handleManagement(state: inout State, request: AgentToolRequest) -> EffectOf<Self> {
        do {
            let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request.arguments ?? [:])) as! [String: Any]
            guard let name = request.tool, try MCPManagementSchema.command(name: name, arguments: raw) == request else {
                throw FeatureFailure(message: "Invalid management request.")
            }
            let args = request.arguments ?? [:]
            if let result = try managementSnapshot(name: name, args: args, state: state) {
                state.agentToolReply = AgentToolReply(data: result); return .none
            }
            guard let id = request.requestID else { throw FeatureFailure(message: "A UUID request_id is required.") }
            let receipt: ToolMutationReceipt?
            if name.hasSuffix("_schedule") { receipt = try management.receipt(id) }
            else { receipt = try? management.receipt(id) }
            if let receipt {
                guard receipt.request == request else { throw FeatureFailure(message: "request_id belongs to different arguments.") }
                var result = receipt.result.object ?? [:]; result["replayed"] = .bool(true)
                state.agentToolReply = AgentToolReply(data: .object(result)); return .none
            }
            if let job = state.agentToolJobs[id] {
                guard state.managedRequests[id] == request else { throw FeatureFailure(message: "request_id belongs to a different request.") }
                state.agentToolReply = AgentToolReply(job: job); return .none
            }
            guard !["get_history", "get_logs", "list_models"].contains(name) ||
                    state.agentToolJobs.values.filter({ $0.phase == .loading }).count < 4 else {
                throw FeatureFailure(message: "Too many pending tool reads. Poll existing jobs before retrying.")
            }
            trackManagement(state: &state, request: request)
            let effect: EffectOf<Self>
            switch name {
            case "create_schedule", "update_schedule", "pause_schedule", "remove_schedule":
                effect = try manageSchedule(state: &state, request: request)
            case "update_settings":
                let patch = args["settings"]?.object ?? [:]
                try ToolSettings.validate(patch)
                effect = try requestManagementApproval(state: &state, request: request, title: "Change DiskSage settings?",
                    details: ToolSettings.details(patch), settings: management.settings().filter { patch[$0.key] != nil })
            case "request_advice": effect = try requestManagedAdvice(state: &state, request: request, approved: false)
            case "delete_candidates": effect = try requestManagedDeletion(state: &state, request: request)
            case "get_history", "get_logs", "list_models":
                effect = .run { [management] send in
                    let result: Result<ToolValue, FeatureFailure>
                    do { result = .success(try await management.read(name, args)) }
                    catch { result = .failure(FeatureFailure(message: error.localizedDescription)) }
                    await send(.managementFinished(id, result))
                }
            default: effect = try manageControls(state: &state, request: request)
            }
            if let job = state.agentToolJobs[id] { state.agentToolReply = AgentToolReply(job: job) }
            return effect
        } catch {
            if let id = request.requestID, state.managedRequests[id] == request {
                state.agentToolJobs[id]?.result = .object(["error": .string(error.localizedDescription)])
                completeAgentJob(state: &state, id: id, phase: .failed)
            }
            state.agentToolReply = AgentToolReply(error: error.localizedDescription)
            return .none
        }
    }

    func reduceManagement(state: inout State, action: Action) -> EffectOf<Self> {
        switch action {
        case let .approveManagement(id):
            guard let pending = state.pendingManagementApproval, pending.id == id else { return .none }
            state.pendingManagementApproval = nil
            do {
                if let schedule = pending.schedule {
                    guard client.preferences().agentPolicy != .disabled else { throw FeatureFailure(message: "Agent cleanup access was disabled while approval was pending.") }
                    guard pending.previousSchedule == state.schedules.first(where: { $0.id == schedule.id }) else {
                        throw FeatureFailure(message: "The schedule changed while approval was pending. Request it again.")
                    }
                    try schedules.validate(schedule)
                    guard !schedule.isEnabled || schedule.nextOccurrence(after: now, calendar: calendar) != nil else {
                        throw FeatureFailure(message: "The approved cleanup time has passed. Request a new time.")
                    }
                    try commitManagedSchedule(state: &state, request: pending.request, schedule: schedule)
                    return .none
                }
                if let previous = pending.previousSettings {
                    let patch = pending.request.arguments?["settings"]?.object ?? [:]
                    guard management.settings().filter({ patch[$0.key] != nil }) == previous else {
                        throw FeatureFailure(message: "These settings changed while approval was pending. Request them again.")
                    }
                    state.agentToolJobs[id]?.phase = .loading
                    return .run { [management] send in
                        do {
                            try await management.applySettings(patch)
                            await send(.managementFinished(id, .success(.object(management.settings()))))
                        } catch { await send(.managementFinished(id, .failure(FeatureFailure(message: error.localizedDescription)))) }
                    }
                }
                if let configuration = pending.configuration {
                    guard ToolSettings.configuration(configuration.provider, values: management.settings()).0 == configuration else {
                        throw FeatureFailure(message: "Advisor configuration changed during approval. Request advice again.")
                    }
                }
                return try requestManagedAdvice(state: &state, request: pending.request, approved: true)
            } catch {
                state.agentToolJobs[id]?.result = .object(["error": .string(error.localizedDescription)])
                completeAgentJob(state: &state, id: id, phase: .failed)
            }
        case let .rejectManagement(id):
            guard state.pendingManagementApproval?.id == id else { return .none }
            state.pendingManagementApproval = nil
            state.agentToolJobs[id]?.result = .object(["message": .string("Request declined in DiskSage. No change was applied.")])
            completeAgentJob(state: &state, id: id, phase: .cancelled)
        case let .managementFinished(id, result):
            guard state.agentToolJobs[id]?.phase == .loading else { return .none }
            switch result {
            case let .success(value): finishManagedValue(state: &state, id: id, value: value)
            case let .failure(error):
                state.agentToolJobs[id]?.result = .object(["error": .string(error.message)])
                completeAgentJob(state: &state, id: id, phase: .failed)
            }
        default: break
        }
        return .none
    }

    func trackManagement(state: inout State, request: AgentToolRequest) {
        guard let id = request.requestID else { return }
        state.managedRequests[id] = request
        state.agentToolJobs[id] = AgentToolJob(id: id, action: .manage, startedAt: now, phase: .loading)
        state.agentToolJobOrder.append(id)
        trimAgentJobs(state: &state)
    }
    func trimAgentJobs(state: inout State) {
        while state.agentToolJobOrder.count > 100,
              let stale = state.agentToolJobOrder.first(where: { state.agentToolJobs[$0]?.phase.isTerminal == true }) {
            state.agentToolJobs[stale] = nil; state.managedRequests[stale] = nil
            state.agentToolJobOrder.removeAll { $0 == stale }
        }
    }
    func finishManagedValue(state: inout State, id: UUID, value: ToolValue) {
        state.agentToolJobs[id]?.result = value
        completeAgentJob(state: &state, id: id, phase: .succeeded)
    }
    func requestManagementApproval(state: inout State, request: AgentToolRequest, title: String, details: String,
        schedule: CleanupSchedule? = nil, previous: CleanupSchedule? = nil,
        settings: [String: ToolValue]? = nil, configuration: AgentConfiguration? = nil) throws -> EffectOf<Self> {
        guard !state.isBusy, let id = request.requestID else { throw FeatureFailure(message: "DiskSage is busy. Wait for the current operation or confirmation.") }
        state.pendingManagementApproval = ManagementApproval(id: id, request: request, title: title, details: details,
            schedule: schedule, previousSchedule: previous, previousSettings: settings, configuration: configuration)
        state.agentToolJobs[id]?.phase = .awaitingConfirmation
        state.agentToolJobs[id]?.result = .object(["confirmation_id": .string(id.uuidString), "message": .string("A person must approve this request in DiskSage.")])
        return .none
    }
}
