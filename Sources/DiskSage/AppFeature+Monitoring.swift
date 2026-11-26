import ComposableArchitecture
import Foundation

extension AppFeature {
    static let capacityCheckIntervalSeconds = 60
    static let automaticRetryInterval: TimeInterval = 15 * 60

    func reduceMonitoring(state: inout State, action: Action) -> EffectOf<Self> {
        switch action {
        case .startMonitoring:
            guard !state.isMonitoring else { return .none }
            state.isMonitoring = true
            return .run { [clock] send in
                await send(.monitorTick)
                while !Task.isCancelled {
                    try await clock.sleep(for: .seconds(Self.capacityCheckIntervalSeconds))
                    await send(.monitorTick)
                }
            }.cancellable(id: CancelID.monitor)
        case .monitoringPreferencesChanged:
            state.automaticRetryAfter = nil
            return state.isMonitoring ? .send(.monitorTick) : .none
        case .stopMonitoring:
            state.isMonitoring = false
            if let id = state.automaticCheckID, state.operationID == id, state.operation == .automaticScan {
                state.operation = .idle
                state.operationID = nil
            }
            state.automaticCheckID = nil
            state.lastAutomaticCheckReason = nil
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
            if let available {
                state.freeSpaceBytes = available
                if let usage = state.diskUsage {
                    state.diskUsage = DiskUsageSnapshot(name: usage.name, totalBytes: usage.totalBytes, availableBytes: available)
                }
            }
            let preferences = client.preferences()
            let threshold = Int64(preferences.thresholdGiB) * 1_024 * 1_024 * 1_024
            // A recovered disk resets the cooldown so the next threshold crossing
            // is handled immediately, even if the previous cleanup was recent.
            if let available, available > threshold { state.automaticRetryAfter = nil }
            let coolingDown = state.automaticRetryAfter.map { now < $0 } ?? false
            let eligible: Bool
            if let available {
                eligible = preferences.automaticEnabled && !wasBusy && !state.isBusy &&
                    revision == state.activityRevision && available <= threshold && !coolingDown
            } else {
                eligible = false
            }
            let reason: String
            if !preferences.automaticEnabled { reason = "Automatic cleanup is disabled." }
            else if wasBusy || state.isBusy || revision != state.activityRevision { reason = "Skipped because another operation is active or user activity changed." }
            else if let available {
                if available > threshold { reason = "Free space is above the \(preferences.thresholdGiB) GiB threshold." }
                else if coolingDown { reason = "Free space is low; waiting for the 15-minute automatic cleanup retry cooldown." }
                else { reason = "Free space is at or below the \(preferences.thresholdGiB) GiB threshold; starting a scan for low-risk items." }
            } else {
                reason = "Available disk space could not be read; automatic cleanup skipped."
            }
            let shouldLog = eligible || state.lastAutomaticCheckReason != reason
            if !shouldLog {
                state.automaticCheckID = nil
                return state.diskUsage == nil ? refreshDashboard(state: &state) : .none
            }
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
                    await send(.automaticCheckLogged(id, eligible, reason, nil))
                } catch {
                    guard !Task.isCancelled else { return }
                    await send(.automaticCheckLogged(id, eligible, reason, FeatureFailure(message: error.localizedDescription)))
                }
            }.cancellable(id: CancelID.monitorCheck)
        case let .automaticCheckLogged(id, reserved, reason, error):
            guard state.automaticCheckID == id else { return .none }
            state.automaticCheckID = nil
            let ownsReservation = reserved && state.operation == .automaticScan && state.operationID == id
            if let error {
                if ownsReservation { state.operation = .idle; state.operationID = nil }
                state.errorMessage = "Automatic cleanup check could not be logged: \(error.message)"
                return .none
            }
            state.lastAutomaticCheckReason = reason
            if ownsReservation {
                let preferences = client.preferences()
                guard preferences.automaticEnabled,
                      let available = client.freeSpace(),
                      available <= Int64(preferences.thresholdGiB) * 1_024 * 1_024 * 1_024 else {
                    state.operation = .idle
                    state.operationID = nil
                    return state.diskUsage == nil ? refreshDashboard(state: &state) : .none
                }
                return beginScan(state: &state, purpose: .automatic, reservedID: id)
            }
            return state.diskUsage == nil ? refreshDashboard(state: &state) : .none
        default: return .none
        }
    }
}
