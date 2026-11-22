import Darwin
import Foundation

struct PathDiagnostic: Codable, Equatable, Sendable {
    enum Verdict: String, Codable, Sendable {
        case eligible
        case skipped
        case outsideScope = "outside_scope"

        var title: String {
            switch self {
            case .eligible: "Eligible"
            case .skipped: "Skipped"
            case .outsideScope: "Outside scope"
            }
        }
    }

    let path: String
    let verdict: Verdict
    let matcher: String
    let risk: String?
    let sizeBytes: Int64?
    let summary: String
    let reasons: [String]

    enum CodingKeys: String, CodingKey {
        case path, verdict, matcher, risk, summary, reasons
        case sizeBytes = "size_bytes"
    }
}

/// Read-only explainer showing whether DiskSage would offer a path for cleanup or exactly which
/// safety guard, age rule, keep rule, or allowlist boundary protects it.
enum PathDiagnostics {
    static func explain(
        _ rawPath: String,
        activity: CleanupActivity,
        now: Date = Date(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        keep: KeepRules = .current(),
        rules: ProjectCacheRules? = nil,
        claudeProjectsDirectory: URL? = nil,
        miseEnv: MiseProjectDiscovery.Environment? = nil,
        git: WorktreeGitProcess = WorktreeGitProcess(),
        simctl: SimulatorInventory.Run = SimulatorInventory.simctl,
        toolRun: ToolCacheInventory.Run = ToolCacheInventory.process,
        toolTrusted: ToolCacheInventory.Trusted = ToolCacheInventory.isTrusted,
        minimumProjectBytes: Int64 = ProjectCacheInventory.defaultMinimumBytes,
        minimumGlobalBytes: Int64 = EcosystemCacheInventory.minimumBytes
    ) -> PathDiagnostic {
        let canonicalHome = CleanupPath.fileURL(home)
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = trimmed == "~" ? canonicalHome.path
            : (trimmed.hasPrefix("~/") ? canonicalHome.path + trimmed.dropFirst(1) : trimmed)
        guard expanded.hasPrefix("/") else {
            return PathDiagnostic(path: trimmed, verdict: .outsideScope, matcher: "Path validation",
                                  risk: nil, sizeBytes: nil, summary: "Path must be absolute or start with ~/.",
                                  reasons: ["Provide an absolute path or a path starting with ~/."])
        }

        let normalized = normalizeSystemPrefix(URL(fileURLWithPath: expanded).standardizedFileURL.path)
        let targetURL = URL(fileURLWithPath: normalized)
        if let symlinkReason = symlinkIssue(for: targetURL) {
            return PathDiagnostic(path: normalized, verdict: .skipped, matcher: "Symlink guard",
                                  risk: nil, sizeBytes: nil, summary: symlinkReason, reasons: [symlinkReason])
        }

        var info = stat()
        guard lstat(normalized, &info) == 0 else {
            let reason = errno == ENOENT ? "Path does not exist." : "Could not inspect path (\(String(cString: strerror(errno))))."
            return PathDiagnostic(path: normalized, verdict: .skipped, matcher: "Filesystem",
                                  risk: nil, sizeBytes: nil, summary: reason, reasons: [reason])
        }

        let url = CleanupPath.fileURL(targetURL)
        if let global = globalSafetyIssue(url, home: canonicalHome, keep: keep) { return global }

        if let tool = ToolCache.matching(url, home: canonicalHome) {
            return explainToolCache(tool, url: url, activity: activity, home: canonicalHome,
                                    run: toolRun, trusted: toolTrusted, minimumBytes: minimumGlobalBytes)
        }
        if let eco = EcosystemCacheInventory.matching(url, home: canonicalHome) {
            return explainEcosystemCache(eco, url: url, activity: activity, now: now, minimumBytes: minimumGlobalBytes)
        }
        if let set = SimulatorInventory.deviceSet(for: url, home: canonicalHome) {
            return explainSimulator(url, set: set, activity: activity, keep: keep, run: simctl)
        }
        if let session = ClaudeSessionActivity.session(containing: url),
           ClaudeSessionActivity.isLive(session, activity: activity, now: now) {
            return skipped(url, matcher: "Claude session guard",
                           reasons: ["A live Claude session still uses this folder."])
        }
        if TemporaryBuildOutput.kind(of: url, home: canonicalHome) != nil {
            let temp = explainTemporaryBuild(url, activity: activity, now: now, home: canonicalHome)
            if temp.verdict == .eligible { return temp }
            if let genRule = GeneratedCleanupScope.rule(for: url, home: canonicalHome) {
                let generated = explainGenerated(url, rule: genRule, activity: activity, now: now,
                                                 home: canonicalHome, keep: keep)
                if generated.verdict == .eligible { return generated }
                return skipped(url, matcher: temp.matcher, reasons: temp.reasons + generated.reasons)
            }
            return temp
        }
        let activeRules = rules ?? ProjectCacheRulesLoader.current(home: canonicalHome)
        if let project = explainProjectCache(url, activity: activity, now: now, home: canonicalHome,
                                             rules: activeRules, claudeDir: claudeProjectsDirectory,
                                             miseEnv: miseEnv, git: git, minimumBytes: minimumProjectBytes) {
            if project.verdict == .eligible { return project }
            if let genRule = GeneratedCleanupScope.rule(for: url, home: canonicalHome) {
                let generated = explainGenerated(url, rule: genRule, activity: activity, now: now,
                                                 home: canonicalHome, keep: keep)
                if generated.verdict == .eligible { return generated }
                return skipped(url, matcher: project.matcher, sizeBytes: project.sizeBytes ?? generated.sizeBytes,
                               reasons: project.reasons + generated.reasons)
            }
            return project
        }
        if let genRule = GeneratedCleanupScope.rule(for: url, home: canonicalHome) {
            return explainGenerated(url, rule: genRule, activity: activity, now: now,
                                    home: canonicalHome, keep: keep)
        }
        return PathDiagnostic(path: url.path, verdict: .outsideScope, matcher: "Allowlist",
                              risk: nil, sizeBytes: nil, summary: "Outside DiskSage's allowlisted cleanup locations.",
                              reasons: ["Path does not match any built-in build, cache, simulator, or project-cache discovery rule."])
    }

    private static func normalizeSystemPrefix(_ path: String) -> String {
        for prefix in ["/var", "/tmp", "/etc"] where path == prefix || path.hasPrefix(prefix + "/") {
            return "/private" + path
        }
        return path
    }

    private static func symlinkIssue(for url: URL) -> String? {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        let components = Array(url.pathComponents.dropFirst())
        for (index, component) in components.enumerated() {
            current.append(path: component)
            var info = stat()
            guard lstat(current.path, &info) == 0 else { return nil }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                return index == components.count - 1
                    ? "Symlinked targets are never followed or offered."
                    : "An ancestor directory is a symlink (\(current.path)), which DiskSage refuses."
            }
        }
        return nil
    }

    private static func globalSafetyIssue(_ url: URL, home: URL, keep: KeepRules) -> PathDiagnostic? {
        let developer = home.appending(path: "Developer", directoryHint: .isDirectory)
        if url.path == "/" || url == home || url == developer {
            return PathDiagnostic(path: url.path, verdict: .outsideScope, matcher: "Safety policy",
                                  risk: nil, sizeBytes: nil, summary: "DiskSage refuses broad root directories.",
                                  reasons: ["Broad root directories (/, ~, ~/Developer) are never cleanup targets."])
        }
        if url.pathComponents.contains(".git") {
            return skipped(url, matcher: "Safety policy", reasons: ["Git metadata (.git) is never a cleanup target."])
        }
        if let executable = Bundle.main.executableURL.map(CleanupPath.fileURL),
           executable.path.hasPrefix(url.path + "/") {
            return skipped(url, matcher: "Safety policy", reasons: ["Contains the running DiskSage executable."])
        }
        if keep.keeps(url) {
            return skipped(url, matcher: "Keep rules", reasons: ["Protected by a Keep rule in Settings."])
        }
        return nil
    }

    private static func explainToolCache(
        _ tool: ToolCache, url: URL, activity: CleanupActivity, home: URL,
        run: ToolCacheInventory.Run, trusted: ToolCacheInventory.Trusted, minimumBytes: Int64
    ) -> PathDiagnostic {
        let matcher = "Tool cache (\(tool.name))"
        guard TemporaryBuildOutput.isRealDirectory(url) else {
            return skipped(url, matcher: matcher, reasons: ["Target is not a real directory."])
        }
        var reasons: [String] = []
        let executable = tool.executables.first(where: trusted)
        if executable == nil { reasons.append("No trusted executable found for \(tool.name).") }
        if activity.contains(url) { reasons.append("A running process has open files in this folder.") }
        var bytes: Int64?
        if let executable {
            let env = ToolCacheInventory.executionEnvironment(for: tool, executable: executable, home: home, trusted: trusted)
            for check in tool.preflightChecks {
                if let out = try? run(executable, check.arguments, env) {
                    if let failure = check.evaluate(code: out.code, text: String(decoding: out.data, as: UTF8.self)) {
                        reasons.append(failure)
                    }
                } else {
                    reasons.append(check.refusalReason)
                }
            }
            if let args = tool.estimateArguments {
                if let out = try? run(executable, args, env), out.code == 0 {
                    bytes = ToolCache.freedBytes(fromDryRun: String(decoding: out.data, as: UTF8.self))
                } else {
                    reasons.append("Tool dry-run size estimate failed.")
                }
            } else {
                bytes = DiskScanner.allocatedSize(of: url)
            }
            if let bytes, bytes < minimumBytes {
                reasons.append("Estimated reclaimable size (\(bytes.diskSize)) is below the \(minimumBytes.diskSize) threshold.")
            }
        }
        guard reasons.isEmpty else { return skipped(url, matcher: matcher, sizeBytes: bytes, reasons: reasons) }
        return PathDiagnostic(path: url.path, verdict: .eligible, matcher: matcher,
                              risk: "low", sizeBytes: bytes, summary: tool.reason, reasons: [])
    }

    private static func explainEcosystemCache(
        _ rule: EcosystemCacheInventory.Rule, url: URL, activity: CleanupActivity, now: Date, minimumBytes: Int64
    ) -> PathDiagnostic {
        let matcher = "Ecosystem cache (\(rule.name))"
        guard TemporaryBuildOutput.isRealDirectory(url) else {
            return skipped(url, matcher: matcher, reasons: ["Target is not a real directory."])
        }
        var reasons: [String] = []
        if activity.contains(url) { reasons.append("A running process has open files in this folder.") }
        let running = activity.commands.intersection(rule.blockedCommands).sorted()
        if !running.isEmpty { reasons.append("Blocked while \(running.joined(separator: ", ")) is running.") }
        var bytes: Int64?
        do {
            let survey = try FolderSurvey.read(url, gitAllowedUnder: [])
            bytes = survey.bytes
            if survey.idle(at: now) < EcosystemCacheInventory.minimumIdle { reasons.append("Cache was modified less than 1 hour ago.") }
            if survey.bytes < minimumBytes { reasons.append("Size (\(survey.bytes.diskSize)) is below the \(minimumBytes.diskSize) threshold.") }
        } catch { reasons.append(error.localizedDescription) }
        do { try EcosystemCacheInventory.verifyNoRefusedNames(in: url, refused: rule.refuseNames) }
        catch { reasons.append(error.localizedDescription) }
        do { try WorktreePathGuard.rejectSourceContainers(url) }
        catch { reasons.append(error.localizedDescription) }
        guard reasons.isEmpty else { return skipped(url, matcher: matcher, sizeBytes: bytes, reasons: reasons) }
        return PathDiagnostic(path: url.path, verdict: .eligible, matcher: matcher,
                              risk: riskKey(rule.risk), sizeBytes: bytes, summary: rule.reason, reasons: [])
    }

    private static func explainSimulator(
        _ url: URL, set: SimulatorInventory.DeviceSet, activity: CleanupActivity, keep: KeepRules, run: SimulatorInventory.Run
    ) -> PathDiagnostic {
        let matcher = set == .previews ? "Xcode Previews simulator" : "Simulator device"
        let udid = url.lastPathComponent.uppercased()
        guard SimulatorDevice.isUDID(udid) else {
            return skipped(url, matcher: matcher, reasons: ["Folder name is not a simulator device UDID."])
        }
        guard let devices = try? SimulatorInventory.devices(in: set, run: run) else {
            return skipped(url, matcher: matcher, reasons: ["simctl could not list simulator devices."])
        }
        guard let device = devices.first(where: { $0.udid == udid }) else {
            return skipped(url, matcher: matcher, reasons: ["No simulator device with UDID \(udid) is registered in simctl."])
        }
        var reasons: [String] = []
        if !device.isShutdown { reasons.append("\(device.name) is currently \(device.state).") }
        if keep.keepsSimulator(named: device.name) { reasons.append("Protected by a kept simulator name pattern in Settings.") }
        if activity.contains(url) { reasons.append("A running process has open files in this simulator.") }
        let bytes = DiskScanner.allocatedSize(of: url)
        if (bytes ?? 0) <= 0 { reasons.append("Simulator folder has zero reclaimable bytes.") }
        guard reasons.isEmpty else { return skipped(url, matcher: matcher, sizeBytes: bytes, reasons: reasons) }
        return PathDiagnostic(path: url.path, verdict: .eligible, matcher: matcher, risk: "medium",
                              sizeBytes: bytes, summary: "Shut-down simulator \(device.name) (\(device.runtimeTitle)).", reasons: [])
    }

    private static func explainTemporaryBuild(_ url: URL, activity: CleanupActivity, now: Date, home: URL) -> PathDiagnostic {
        if let candidate = TemporaryBuildInspector.inspect(url, activity: activity, now: now, home: home) {
            return PathDiagnostic(path: url.path, verdict: .eligible, matcher: "Temporary build output",
                                  risk: riskKey(candidate.risk), sizeBytes: candidate.size, summary: candidate.reason, reasons: [])
        }
        var reasons: [String] = []
        if activity.contains(url) { reasons.append("A running process is using this build folder.") }
        let probe = CleanupCandidate(url: url, name: url.lastPathComponent, category: .build, size: 1,
                                     risk: .low, reason: "", deletionMode: .item)
        do { try TemporaryBuildInspector.verifyBeforeDeletion(probe, activity: activity, now: now, home: home) }
        catch { reasons.append(error.localizedDescription) }
        if reasons.isEmpty { reasons.append("Does not yet meet age, size, or workspace criteria for whole-folder cleanup.") }
        return skipped(url, matcher: "Temporary build output", reasons: reasons)
    }

    private static func explainProjectCache(
        _ url: URL, activity: CleanupActivity, now: Date, home: URL, rules: ProjectCacheRules,
        claudeDir: URL?, miseEnv: MiseProjectDiscovery.Environment?, git: WorktreeGitProcess, minimumBytes: Int64
    ) -> PathDiagnostic? {
        let roots = ProjectCacheInventory.discoveryRoots(home: home, miseEnv: miseEnv)
        guard let matchingRoot = roots.first(where: { url.path.hasPrefix($0.path + "/") }) else { return nil }
        let relFromRoot = String(url.path.dropFirst(matchingRoot.path.count + 1))
        if let skippedPart = relFromRoot.split(separator: "/").map(String.init).first(where: { rules.skip.contains($0) }) {
            // Built-in build folders (.build, DerivedData) are skipped here so GeneratedCleanupScope handles them.
            if GeneratedCleanupScope.rule(for: url, home: home) != nil { return nil }
            return skipped(url, matcher: "Project cache rules", reasons: ["'\(skippedPart)' is in the project-cache skip list."])
        }
        guard let hit = rules.matchDirectory(url, under: matchingRoot) else {
            let name = url.lastPathComponent
            if rules.names.contains(name), let markers = rules.beside[name], !markers.isEmpty {
                return skipped(url, matcher: "Project cache (\(name))",
                               reasons: ["Matches cache name '\(name)', but none of the required project markers (\(markers.joined(separator: ", "))) exist beside it."])
            }
            return nil
        }

        let matcher = "Project cache (\(hit.label))"
        guard TemporaryBuildOutput.isRealDirectory(url) else {
            return skipped(url, matcher: matcher, reasons: ["Target is not a real directory."])
        }
        var reasons: [String] = []
        if activity.contains(url) { reasons.append("A running process has open files in this folder.") }
        if let repo = ProjectCacheInventory.gitWorkTreeTopLevel(for: url.deletingLastPathComponent(), git: git) {
            do { try ProjectCacheInventory.verifyGitIgnoredAndUntracked(cacheURL: url, repoRoot: repo, git: git) }
            catch { reasons.append(error.localizedDescription) }
            let resolvedClaudeDir = claudeDir ?? ProjectCacheInventory.defaultClaudeProjectsDirectory(home: home)
            let folders = ProjectCacheInventory.listSubdirectories(resolvedClaudeDir)
            if let last = ProjectCacheInventory.projectLastActivity(root: repo, claudeDir: resolvedClaudeDir,
                                                                    claudeFolders: folders, git: git) {
                if now.timeIntervalSince(last) < rules.quietHours * 3_600 {
                    reasons.append("Owning project had Git or Claude Code activity within the \(Int(rules.quietHours))-hour quiet period.")
                }
            } else {
                reasons.append("Could not read Git activity timestamp for the owning repository.")
            }
        } else {
            reasons.append("Not inside a Git work tree.")
        }
        do {
            if let blocked = try ProjectCacheRules.refuseInsideViolation(in: url, patterns: hit.refuseInside) {
                reasons.append("Contains protected path '\(blocked)' matching refuse_inside rules.")
            }
        } catch { reasons.append(error.localizedDescription) }
        var bytes: Int64?
        do {
            let survey = try FolderSurvey.read(url, gitAllowedUnder: [])
            bytes = survey.bytes
            if survey.idle(at: now) < rules.quietHours * 3_600 {
                reasons.append("Cache folder was modified within the \(Int(rules.quietHours))-hour quiet period.")
            }
            if survey.bytes < minimumBytes {
                reasons.append("Size (\(survey.bytes.diskSize)) is below the \(minimumBytes.diskSize) threshold.")
            }
        } catch { reasons.append(error.localizedDescription) }
        do { try WorktreePathGuard.rejectSourceContainers(url) }
        catch { reasons.append(error.localizedDescription) }
        guard reasons.isEmpty else { return skipped(url, matcher: matcher, sizeBytes: bytes, reasons: reasons) }
        return PathDiagnostic(path: url.path, verdict: .eligible, matcher: matcher, risk: "low", sizeBytes: bytes,
                              summary: "Git-ignored project cache (\(hit.label)) in a quiet repository with no tracked files.",
                              reasons: [])
    }

    private static func explainGenerated(_ url: URL, rule: GeneratedCleanupRule, activity: CleanupActivity,
                                         now: Date, home: URL, keep: KeepRules) -> PathDiagnostic {
        if activity.contains(url, rule: rule) {
            return skipped(url, matcher: "Generated files", reasons: ["Folder or toolchain is currently in use."])
        }
        do {
            let cutoff = now.addingTimeInterval(-GeneratedCleanupPolicy.minimumAge)
            let policy = SafetyPolicy(home: home, now: now, keep: keep)
            if let candidate = try GeneratedFileDeleter.inspect(url, name: url.lastPathComponent, category: .build,
                                                                rule: rule, activity: activity, cutoff: cutoff,
                                                                policy: policy, handsOffWholeFolders: false) {
                return PathDiagnostic(path: url.path, verdict: .eligible, matcher: "Generated files",
                                      risk: riskKey(candidate.risk), sizeBytes: candidate.size, summary: candidate.reason, reasons: [])
            }
            return skipped(url, matcher: "Generated files",
                           reasons: ["No verified generated files older than 1 hour were found inside this folder."])
        } catch {
            return skipped(url, matcher: "Generated files", reasons: [error.localizedDescription])
        }
    }

    private static func skipped(_ url: URL, matcher: String, sizeBytes: Int64? = nil, reasons: [String]) -> PathDiagnostic {
        let deduped = Array(NSOrderedSet(array: reasons).compactMap { $0 as? String })
        return PathDiagnostic(path: url.path, verdict: .skipped, matcher: matcher, risk: nil, sizeBytes: sizeBytes,
                              summary: deduped.first ?? "Skipped by DiskSage safety rules.", reasons: deduped)
    }

    private static func riskKey(_ risk: RiskLevel) -> String {
        switch risk { case .low: "low"; case .medium: "medium"; case .high: "high" }
    }
}
