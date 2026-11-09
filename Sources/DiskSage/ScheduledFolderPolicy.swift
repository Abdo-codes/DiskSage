import Darwin
import Foundation

/// Explicit folder authorization is separate from the scanner's global allowlist.
enum ScheduledFolderPolicy {
    static func identity(of folder: URL, scope: CleanupSchedule.Scope = .folderContents) throws -> FileIdentity {
        guard folder.isFileURL, folder.host == nil || folder.host == "localhost" else {
            throw FeatureFailure(message: "Choose a local folder.")
        }
        let url = CleanupPath.fileURL(folder)
        let path = url.path.lowercased()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let protected = ["/", "/Users", "/Volumes", "/private", "/private/tmp", "/private/var", "/tmp",
                         "/var", home.path, home.appending(path: "Developer").path,
                         home.appending(path: "Library").path]
        let system = ["/system", "/library", "/applications", "/usr", "/bin", "/sbin", "/etc", "/dev",
                      "/private/etc", "/private/var/db", "/private/var/run", "/private/var/root", "/private/var/log", "/private/var/vm"]
        guard !protected.map({ $0.lowercased() }).contains(path), url.pathComponents.count > 2,
              !(url.pathComponents.count == 3 && path.hasPrefix("/volumes/")),
              !system.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
              !url.pathComponents.contains(where: { $0.lowercased() == ".git" || $0.lowercased().hasSuffix(".app") }) else {
            throw FeatureFailure(message: "Choose a specific cleanup folder, outside system folders, apps, and Git data.")
        }
        if let executable = Bundle.main.executableURL.map(CleanupPath.fileURL),
           executable.path.lowercased().hasPrefix(path + "/") {
            throw FeatureFailure(message: "The folder contains the running DiskSage executable.")
        }
        let appData = ["Library/Application Support/DiskSage", "Library/Logs/DiskSage"]
            .map { home.appending(path: $0).path.lowercased() }
        guard !appData.contains(where: { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) else {
            throw FeatureFailure(message: "DiskSage’s settings, agent connection, and cleanup logs cannot be scheduled for deletion.")
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        var info = stat()
        for component in url.pathComponents.dropFirst() {
            current.append(path: component)
            guard lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                throw FeatureFailure(message: "A folder path component is missing, inaccessible, or symlinked: \(current.path)")
            }
        }
        if scope != .lowRisk { try WorktreePathGuard.rejectSourceContainers(url) }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    /// Runs at scan and again before deletion. Keep rules added after the schedule was authorized still apply.
    static func validate(_ schedule: CleanupSchedule, keep: KeepRules = .current(),
                         home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         simctl: SimulatorInventory.Run = SimulatorInventory.simctl) throws {
        guard !keep.keeps(schedule.folder) else {
            throw SafetyPolicyError.refused("A keep rule in Settings protects this folder or something inside it.")
        }
        // A schedule over simulator data must not reach a device whose name is kept. If simctl fails, nothing is deleted.
        if !keep.simulatorNames.isEmpty,
           KeepRules(paths: [SimulatorInventory.devicesRoot(home: home).path]).keeps(schedule.folder) {
            let kept = try SimulatorInventory.keptDeviceFolders(keep, home: home, run: simctl)
            guard !KeepRules(paths: kept.map(\.path)).keeps(schedule.folder) else {
                throw SafetyPolicyError.refused("A keep rule in Settings protects a simulator in this folder.")
            }
        }
        guard try identity(of: schedule.folder, scope: schedule.scope) == schedule.folderIdentity else {
            throw FeatureFailure(message: "The scheduled folder was replaced. Choose it again to authorize the new folder.")
        }
        if schedule.scope == .lowRisk { _ = try lowRiskCategory(schedule.folder) }
    }

    static func lowRiskCategory(_ folder: URL) throws -> CandidateCategory {
        guard let rule = GeneratedCleanupScope.rule(for: folder) else {
            throw FeatureFailure(message: "Choose a recognized generated-file folder, or explicitly authorize all folder contents.")
        }
        return rule == .buildArtifacts || rule == .goBuild ? .build : .cache
    }

    static func scan(_ schedule: CleanupSchedule,
                     activity: GeneratedFileDeleter.Activity = { try CleanupActivity.capture() }) throws -> [CleanupCandidate] {
        try validate(schedule)
        let category: CandidateCategory = schedule.scope == .lowRisk ? try lowRiskCategory(schedule.folder) : .cache
        let currentActivity = try activity()
        try currentActivity.requireIdle(schedule.folder)
        if schedule.scope == .lowRisk {
            guard let rule = GeneratedCleanupScope.rule(for: schedule.folder),
                  let target = try GeneratedFileDeleter.inspect(schedule.folder, name: schedule.folder.lastPathComponent,
                    category: category, rule: rule, activity: currentActivity) else { return [] }
            return [target]
        }
        guard !Task.isCancelled else { throw CancellationError() }
        let size = DiskScanner.allocatedSize(of: schedule.folder) ?? 0
        guard !Task.isCancelled else { throw CancellationError() }
        // Empty directories and zero-byte entries still need scheduled cleanup.
        let children = try FileManager.default.contentsOfDirectory(atPath: schedule.folder.path)
        guard !children.isEmpty else { return [] }
        return [CleanupCandidate(url: schedule.folder, name: schedule.folder.lastPathComponent,
            category: category, size: size, risk: schedule.scope == .lowRisk ? .low : .medium,
            reason: "Scheduled folder cleanup; the selected folder remains.",
            identity: schedule.folderIdentity, deletionMode: .contents)]
    }

    static func delete(_ schedule: CleanupSchedule, candidates: [CleanupCandidate],
                       repository: CleanupScheduleRepository = .standard,
                       logger: CleanupLogger = .shared,
                       progress: @escaping @Sendable (CleanupProgress) async -> Void) async -> CleanupReport {
        let service = CleanupService(logger: logger, remove: { candidate, removed in
            guard let current = try repository.load().first(where: { $0.id == schedule.id }),
                  current.isEnabled, current.hasSameAuthorization(as: schedule),
                  current.revision == schedule.revision,
                  candidate.url.standardizedFileURL.path == schedule.folder.standardizedFileURL.path,
                  candidate.deletionMode == (schedule.scope == .lowRisk ? .generatedFiles : .contents), candidate.identity == schedule.folderIdentity else {
                throw FeatureFailure(message: "The schedule was paused, removed, or its folder authorization changed.")
            }
            try validate(current)
            if current.scope == .lowRisk {
                try GeneratedFileDeleter.delete(candidate, entryRemoved: removed)
            } else {
                try CleanupActivity.capture().requireIdle(candidate.url)
                try SecureFileDeleter.delete(candidate, entryRemoved: removed)
            }
        })
        return await service.delete(candidates, trigger: .scheduled, progress: progress)
    }
}
