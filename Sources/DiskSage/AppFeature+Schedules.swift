import ComposableArchitecture
import Foundation

extension AppFeature {
    func reduceSchedules(state: inout State, action: Action) -> EffectOf<Self> {
        switch action {
        case .startScheduling:
            guard !state.isScheduling else { return .none }
            do {
                state.schedules = try schedules.load()
                var paused = false
                for index in state.schedules.indices where state.schedules[index].isEnabled {
                    do { try schedules.validate(state.schedules[index]) }
                    catch {
                        state.schedules[index].isEnabled = false
                        state.schedules[index].revision &+= 1
                        state.schedules[index].lastResult = "Paused: \(error.localizedDescription) Choose the folder again."
                        paused = true
                    }
                }
                if paused { try schedules.save(state.schedules) }
                state.schedulesLoaded = true
                state.scheduleError = nil
                state.schedulingBlocked = false
            } catch {
                state.schedulesLoaded = false
                state.schedulingBlocked = true
                state.scheduleError = "Schedules could not be loaded: \(error.localizedDescription)"
                return .none
            }
            state.isScheduling = true
            return .run { [clock] send in
                await send(.scheduleTick)
                while !Task.isCancelled {
                    try await clock.sleep(for: .seconds(30))
                    await send(.scheduleTick)
                }
            }.cancellable(id: CancelID.schedules)
        case .stopScheduling:
            state.isScheduling = false
            if state.activeSchedule != nil, !state.isCleaning {
                state.operation = .idle; state.operationID = nil
                finishScheduleAttempt(state: &state, message: "Scheduled cleanup cancelled.")
                return .merge(.cancel(id: CancelID.schedules), .cancel(id: CancelID.scan))
            }
            return .cancel(id: CancelID.schedules)
        case var .saveSchedule(value):
            guard state.schedulesLoaded else { return .none }
            do {
                try schedules.validate(value)
                value.nextRun = value.nextOccurrence(after: now, calendar: calendar)
                value.timeZoneIdentifier = calendar.timeZone.identifier
                value.revision = (state.schedules.first(where: { $0.id == value.id })?.revision ?? 0) &+ 1
                guard !value.isEnabled || value.nextRun != nil else {
                    throw FeatureFailure(message: "Choose a future cleanup time.")
                }
                var updated = state.schedules.filter { $0.id != value.id }
                updated.append(value)
                try persistSchedules(updated, state: &state)
            } catch { state.scheduleError = error.localizedDescription }
        case let .setScheduleEnabled(id, enabled):
            guard state.schedulesLoaded else { return .none }
            guard var value = state.schedules.first(where: { $0.id == id }) else { return .none }
            value.isEnabled = enabled
            if enabled { return reduceSchedules(state: &state, action: .saveSchedule(value)) }
            value.revision &+= 1
            do {
                try persistSchedules(state.schedules.map { $0.id == id ? value : $0 }, state: &state)
            } catch { state.scheduleError = error.localizedDescription }
        case let .removeSchedule(id):
            guard state.schedulesLoaded else { return .none }
            do { try persistSchedules(state.schedules.filter { $0.id != id }, state: &state) }
            catch { state.scheduleError = error.localizedDescription }
        case .scheduleTick:
            guard state.isScheduling, state.schedulesLoaded, !state.schedulingBlocked, !state.isBusy else { return .none }
            if state.schedules.contains(where: { $0.isEnabled && $0.frequency != .once &&
                $0.timeZoneIdentifier != calendar.timeZone.identifier }) {
                let updated = state.schedules.map { value -> CleanupSchedule in
                    guard value.isEnabled, value.frequency != .once,
                          value.timeZoneIdentifier != calendar.timeZone.identifier else { return value }
                    var value = value
                    value.timeZoneIdentifier = calendar.timeZone.identifier
                    value.nextRun = value.nextOccurrence(after: now, calendar: calendar)
                    return value
                }
                do { try persistSchedules(updated, state: &state) }
                catch { state.scheduleError = error.localizedDescription; return .none }
            }
            guard let due = state.schedules.filter({ $0.isEnabled && ($0.nextRun.map { $0 <= now } ?? false) })
                    .min(by: { $0.nextRun! < $1.nextRun! }) else { return .none }
            // Persist consumption BEFORE scanning/deleting. Restarting cannot repeat the same occurrence.
            var claimed = due
            claimed.lastRun = now
            claimed.nextRun = claimed.nextOccurrence(after: now, calendar: calendar)
            claimed.lastResult = "Cleanup started. If DiskSage quits, check History before running again."
            do { try persistSchedules(state.schedules.map { $0.id == due.id ? claimed : $0 }, state: &state) }
            catch { state.scheduleError = error.localizedDescription; return .none }
            let id = uuid()
            state.activityRevision += 1
            state.operation = .scanning
            state.operationID = id
            state.activeSchedule = ScheduledCleanupRun(schedule: claimed, operationID: id)
            state.statusMessage = "Checking scheduled folder \(due.folder.lastPathComponent)…"
            return .run { [schedules, client, claimed] send in
                let result: Result<[CleanupCandidate], FeatureFailure>
                do {
                    try await client.logCheck(CleanupLogEvent(runID: id, trigger: .scheduled, event: .check,
                        path: due.folder.path, message: "Scheduled cleanup of \(due.folder.path)."))
                    result = .success(try await schedules.scan(claimed))
                } catch { result = .failure(FeatureFailure(message: error.localizedDescription)) }
                guard !Task.isCancelled else { return }
                await send(.scheduledScanFinished(id, result))
            }.cancellable(id: CancelID.scan)
        case let .scheduledScanFinished(id, result):
            guard let run = state.activeSchedule, run.operationID == id,
                  state.operationID == id, state.operation == .scanning else { return .none }
            guard let current = state.schedules.first(where: { $0.id == run.schedule.id }),
                  current.isEnabled, current.hasSameAuthorization(as: run.schedule),
                  current.revision == run.schedule.revision,
                  current.nextRun == run.schedule.nextRun, !state.schedulingBlocked else {
                state.operation = .idle; state.operationID = nil
                finishScheduleAttempt(state: &state, message: "Skipped: schedule changed or was paused.")
                return .none
            }
            switch result {
            case let .failure(error):
                state.operation = .idle; state.operationID = nil
                finishScheduleAttempt(state: &state, message: "Cleanup failed: \(error.message)")
                state.errorMessage = error.message
                return .none
            case let .success(targets):
                guard !targets.isEmpty else {
                    state.operation = .idle; state.operationID = nil
                    finishScheduleAttempt(state: &state, message: "No eligible inactive files to clean.")
                    return .none
                }
                // Even injected scan results cannot expand this schedule's folder authorization.
                guard targets.allSatisfy({ $0.url.standardizedFileURL.path == current.folder.standardizedFileURL.path &&
                    $0.identity == current.folderIdentity && $0.deletionMode == (current.scope == .lowRisk ? .generatedFiles : .contents) &&
                    (current.scope != .lowRisk || $0.risk == .low) }) else {
                    state.operation = .idle; state.operationID = nil
                    finishScheduleAttempt(state: &state, message: "Cleanup refused: scan returned an unauthorized target.")
                    return .none
                }
                return beginCleanup(state: &state, targets: targets, trigger: .scheduled,
                    cleanupAction: { [schedules] targets, _, progress in
                        await schedules.cleanup(current, targets, progress)
                    })
            }
        default: break
        }
        return .none
    }

    func persistSchedules(_ values: [CleanupSchedule], state: inout State) throws {
        do { try schedules.save(values) }
        catch { state.schedulingBlocked = true; throw error }
        state.schedules = values
        state.scheduleError = nil
        state.schedulingBlocked = false
    }

    func finishScheduleAttempt(state: inout State, message: String) {
        guard let run = state.activeSchedule else { return }
        state.activeSchedule = nil
        state.statusMessage = message
        guard let index = state.schedules.firstIndex(where: { $0.id == run.schedule.id }),
              state.schedules[index].hasSameAuthorization(as: run.schedule),
              state.schedules[index].nextRun == run.schedule.nextRun else { return }
        var updated = state.schedules
        updated[index].lastResult = message
        if updated[index].frequency == .once { updated[index].isEnabled = false }
        do { try persistSchedules(updated, state: &state) }
        catch { state.scheduleError = "The last schedule result could not be saved: \(error.localizedDescription)" }
    }

    func finishScheduledCleanup(state: inout State, report: CleanupReport) -> EffectOf<Self> {
        let paths = Set(report.items.filter(\.succeeded).map { $0.candidate.url.standardizedFileURL.path })
        let stale = Set(state.candidates.filter { paths.contains($0.url.standardizedFileURL.path) }.map(\.id))
        state.candidates.removeAll { stale.contains($0.id) }
        state.selection.subtract(stale)
        for id in stale { state.recommendations[id] = nil }
        let summary = report.failures.isEmpty && report.loggingError == nil ? state.statusMessage :
            "Cleanup finished with errors. See History for details."
        finishScheduleAttempt(state: &state, message: summary)
        return .none
    }
}
