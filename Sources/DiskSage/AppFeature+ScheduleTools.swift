import ComposableArchitecture
import Foundation

extension AppFeature {
    func manageSchedule(state: inout State, request: AgentToolRequest) throws -> EffectOf<Self> {
        guard state.schedulesLoaded, !state.schedulingBlocked, let id = request.requestID else {
            throw FeatureFailure(message: "Schedules are unavailable. Open DiskSage and reload Schedules in Settings.")
        }
        let args = request.arguments ?? [:], name = request.tool ?? ""
        let previous: CleanupSchedule?
        if name == "create_schedule" {
            guard !state.schedules.contains(where: { $0.id == id }) else { throw FeatureFailure(message: "A schedule already uses this request_id. Read it before retrying.") }
            previous = nil
        } else {
            guard let scheduleID = args["schedule_id"]?.string.flatMap(UUID.init(uuidString:)),
                  let existing = state.schedules.first(where: { $0.id == scheduleID }),
                  let revision = args["expected_revision"]?.integer, existing.revision == UInt64(revision) else {
                throw FeatureFailure(message: "Unknown schedule or stale revision. Call list_schedules and use its latest revision.")
            }
            previous = existing
        }
        if name == "pause_schedule" || name == "remove_schedule" {
            var values = state.schedules
            if name == "remove_schedule" { values.removeAll { $0.id == previous!.id } }
            else {
                let index = values.firstIndex { $0.id == previous!.id }!
                values[index].isEnabled = false; values[index].revision &+= 1
            }
            let result: ToolValue = name == "remove_schedule"
                ? .object(["removed_schedule_id": .string(previous!.id.uuidString), "files_deleted": .bool(false)])
                : .object(["schedule": try scheduleSummary(values.first { $0.id == previous!.id }!)])
            try persistManagedSchedules(state: &state, request: request, values: values, result: result)
            return .none
        }
        guard client.preferences().agentPolicy != .disabled else { throw FeatureFailure(message: "Agent cleanup is disabled. Change access in DiskSage first.") }
        var value = previous ?? CleanupSchedule(id: id, folder: URL(fileURLWithPath: "/"), folderIdentity: FileIdentity(device: 0, inode: 0))
        let controls = Set(["request_id", "schedule_id", "expected_revision"])
        guard name == "create_schedule" || !Set(args.keys).subtracting(controls).isEmpty else {
            throw FeatureFailure(message: "Supply at least one schedule field to update.")
        }
        if args["path"] != nil && args["target"] == nil { throw FeatureFailure(message: "Set target=folder when supplying path.") }
        if let target = args["target"]?.string {
            value.folder = try scheduleFolder(target, path: args["path"]?.string)
            value.folderIdentity = try management.identity(value.folder)
        }
        if let scope = args["scope"]?.string { value.scope = CleanupSchedule.Scope(rawValue: scope)! }
        if let frequency = args["frequency"]?.string {
            value.frequency = CleanupSchedule.Frequency(rawValue: frequency)!
            if value.frequency == .once {
                guard args["run_at"] != nil else { throw FeatureFailure(message: "One-time schedules require run_at with a UTC offset.") }
            } else {
                guard args["hour"] != nil, args["minute"] != nil,
                      value.frequency != .weekly || args["weekday"] != nil else {
                    throw FeatureFailure(message: "Recurring schedules require hour and minute; weekly also requires weekday (Sunday=1).")
                }
            }
        }
        if value.frequency == .once, args["hour"] != nil || args["minute"] != nil || args["weekday"] != nil {
            throw FeatureFailure(message: "One-time schedules use run_at, not recurring time fields.")
        }
        if value.frequency != .once, args["run_at"] != nil { throw FeatureFailure(message: "run_at is only valid for frequency=once.") }
        if value.frequency != .weekly, args["weekday"] != nil { throw FeatureFailure(message: "weekday is only valid for weekly schedules.") }
        value.hour = args["hour"]?.integer ?? value.hour; value.minute = args["minute"]?.integer ?? value.minute
        value.weekday = args["weekday"]?.integer ?? value.weekday
        if let raw = args["run_at"]?.string { value.oneTimeDate = MCPManagementSchema.parseDate(raw)! }
        value.isEnabled = args["enabled"]?.bool ?? value.isEnabled
        value.timeZoneIdentifier = calendar.timeZone.identifier
        value.nextRun = value.nextOccurrence(after: now, calendar: calendar)
        value.revision = (previous?.revision ?? 0) &+ 1
        guard (0...23).contains(value.hour), (0...59).contains(value.minute), (1...7).contains(value.weekday) else {
            throw FeatureFailure(message: "Stored schedule timing is invalid. Supply valid hour, minute, and weekday values.")
        }
        try schedules.validate(value)
        guard !value.isEnabled || value.nextRun != nil else { throw FeatureFailure(message: "Choose a future cleanup time.") }
        if value.scope == .folderContents || previous?.scope == .folderContents {
            return try requestManagementApproval(state: &state, request: request,
                title: "Authorize scheduled folder cleanup?",
                details: "Folder: \(value.folder.path)\nRemove: \(String(localized: value.scope.title))\nWhen: \(scheduleTiming(value))\nNext run: \(value.nextRun?.formatted() ?? "None")\nSchedule: \(value.isEnabled ? "Enabled" : "Paused")\n\nCleanup permanently deletes the folder's contents. The selected folder remains. Files do not go to the Trash. Recurring times follow this Mac’s time zone.",
                schedule: value, previous: previous)
        }
        if client.preferences().agentPolicy == .confirm { value.isEnabled = false }
        try commitManagedSchedule(state: &state, request: request, schedule: value)
        return .none
    }

    func commitManagedSchedule(state: inout State, request: AgentToolRequest, schedule: CleanupSchedule) throws {
        var value = schedule
        value.nextRun = value.nextOccurrence(after: now, calendar: calendar)
        let values = state.schedules.filter { $0.id != value.id } + [value]
        let requestedEnabled = request.arguments?["enabled"]?.bool ?? (request.tool == "create_schedule" ? true :
            state.schedules.first(where: { $0.id == schedule.id })?.isEnabled ?? schedule.isEnabled)
        let result: ToolValue = .object(["schedule": try scheduleSummary(value),
            "requires_in_app_enable": .bool(requestedEnabled && !value.isEnabled),
            "message": .string(value.isEnabled ? "Schedule registered. DiskSage must remain running." : "Schedule saved paused. Enable it in Settings to allow cleanup.")])
        try persistManagedSchedules(state: &state, request: request, values: values, result: result)
    }
    func persistManagedSchedules(state: inout State, request: AgentToolRequest, values: [CleanupSchedule], result: ToolValue) throws {
        do { try management.save(values, ToolMutationReceipt(request: request, result: result, timestamp: now)) }
        catch { state.schedulingBlocked = true; state.scheduleError = error.localizedDescription; throw error }
        state.schedules = values; state.scheduleError = nil; state.schedulingBlocked = false
        finishManagedValue(state: &state, id: request.requestID!, value: result)
    }
    func scheduleFolder(_ target: String, path: String?) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard target == "folder" || path == nil else { throw FeatureFailure(message: "Presets do not accept a path override.") }
        switch target {
        case "xcode_derived_data": return home.appending(path: "Library/Developer/Xcode/DerivedData", directoryHint: .isDirectory)
        case "npm_cache": return home.appending(path: ".npm/_cacache", directoryHint: .isDirectory)
        case "bazel_cache": return URL(fileURLWithPath: "/private/var/tmp/_bazel_\(NSUserName())", isDirectory: true)
        default:
            guard let path, path.hasPrefix("/"), !path.contains("\0") else { throw FeatureFailure(message: "Folder targets require an absolute local path.") }
            return CleanupPath.fileURL(URL(fileURLWithPath: path, isDirectory: true))
        }
    }
    func scheduleTiming(_ value: CleanupSchedule) -> String {
        let time = String(format: "%02d:%02d", value.hour, value.minute)
        switch value.frequency {
        case .daily: return "Daily at \(time)"
        case .weekly: return "Every \(calendar.weekdaySymbols[value.weekday - 1]) at \(time)"
        case .once: return "Once at \(value.oneTimeDate.formatted(date: .complete, time: .shortened))"
        }
    }
    func scheduleSummary(_ value: CleanupSchedule) throws -> ToolValue {
        var result = try ToolValue.encode(value).object!
        result["folderIdentity"] = nil
        result["folder"] = .string(value.folder.path)
        return .object(result)
    }
}
