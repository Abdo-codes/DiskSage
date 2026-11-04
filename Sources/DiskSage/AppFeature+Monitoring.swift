import ComposableArchitecture
import Foundation

extension AppFeature {
    func reduceMonitoring(state: inout State, action: Action) -> EffectOf<Self> {
        switch action {
        case .startMonitoring:
            guard !state.isMonitoring else { return .none }
            state.isMonitoring = true
            return .run { [clock] send in
                await send(.monitorTick)
                while !Task.isCancelled {
                    try await clock.sleep(for: .seconds(3_600))
                    await send(.monitorTick)
                }
            }.cancellable(id: CancelID.monitor)
        case .stopMonitoring:
            state.isMonitoring = false
            if let id = state.automaticCheckID, state.operationID == id, state.operation == .automaticScan {
                state.operation = .idle
                state.operationID = nil
            }
            state.automaticCheckID = nil
            return .merge(.cancel(id: CancelID.monitor), .cancel(id: CancelID.monitorCheck))
        case .monitorTick:
            guard state.automaticCheckID == nil else { return .none }
            let id = uuid()
            let revision = state.activityRevision
            let wasBusy = state.isBusy
            state.automaticCheckID = id
            return .run { [client] send in
                let available = await client.capacity()
                guard !Task.isCancelled else { return }
                await send(.capacityRead(id, revision, wasBusy, available))
            }.cancellable(id: CancelID.monitorCheck)
        case let .capacityRead(id, revision, wasBusy, available):
            guard state.automaticCheckID == id else { return .none }
            state.freeSpaceBytes = available
            let preferences = client.preferences()
            let threshold = Int64(preferences.thresholdGiB) * 1_024 * 1_024 * 1_024
            let eligible = preferences.automaticEnabled && !wasBusy && !state.isBusy &&
                revision == state.activityRevision && available <= threshold
            let reason: String
            if !preferences.automaticEnabled { reason = "Automatic cleanup is disabled." }
            else if wasBusy || state.isBusy || revision != state.activityRevision { reason = "Skipped because another operation is active or user activity changed." }
            else if available > threshold { reason = "Free space is above the \(preferences.thresholdGiB) GiB threshold." }
            else { reason = "Free space is at or below the \(preferences.thresholdGiB) GiB threshold; starting a scan for low-risk items." }
            if eligible {
                // Reserve the shared operation while its mandatory check log is being persisted.
                state.operation = .automaticScan
                state.operationID = id
            }
            let event = CleanupLogEvent(timestamp: now, runID: id, trigger: .automatic, event: .check,
                message: reason, freeSpaceBefore: available)
            return .run { [client] send in
                do {
                    try await client.logCheck(event)
                    guard !Task.isCancelled else { return }
                    await send(.automaticCheckLogged(id, eligible, nil))
                } catch {
                    guard !Task.isCancelled else { return }
                    await send(.automaticCheckLogged(id, eligible, FeatureFailure(message: error.localizedDescription)))
                }
            }.cancellable(id: CancelID.monitorCheck)
        case let .automaticCheckLogged(id, reserved, error):
            guard state.automaticCheckID == id else { return .none }
            state.automaticCheckID = nil
            let ownsReservation = reserved && state.operation == .automaticScan && state.operationID == id
            if let error {
                if ownsReservation { state.operation = .idle; state.operationID = nil }
                state.errorMessage = "Automatic cleanup check could not be logged: \(error.message)"
                return .none
            }
            if ownsReservation {
                let preferences = client.preferences()
                guard preferences.automaticEnabled,
                      client.freeSpace() <= Int64(preferences.thresholdGiB) * 1_024 * 1_024 * 1_024 else {
                    state.operation = .idle
                    state.operationID = nil
                    return refreshDashboard(state: &state)
                }
                return beginScan(state: &state, purpose: .automatic, reservedID: id)
            }
            return refreshDashboard(state: &state)
        default: return .none
        }
    }
}
