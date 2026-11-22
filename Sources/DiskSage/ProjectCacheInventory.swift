import Darwin
import Foundation

/// Discovers and validates disposable per-project caches inside quiet Git repositories.
/// A cache is offered only when Git ignores it, it contains zero tracked files and zero nested
/// Git repositories, no protected `refuseInside` entry exists, no running process uses it,
/// and both the project and cache have been quiet for at least `rules.quietHours`.
enum ProjectCacheInventory {
    static let defaultMinimumBytes: Int64 = 10 * 1_048_576
    static let discoveryDepthLimit = 5
    static let discoveryDirectoryLimit = 100_000
    static let projectWalkDirectoryLimit = 100_000

    static func discoveryRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               miseEnv: MiseProjectDiscovery.Environment? = nil) -> [URL] {
        let home = CleanupPath.fileURL(home)
        let builtIn = [
            home.appending(path: "Developer", directoryHint: .isDirectory),
            home.appending(path: "Documents/Codex", directoryHint: .isDirectory),
        ]
        let miseRoots = MiseProjectDiscovery.projectRoots(home: home, env: miseEnv)
        return MiseProjectDiscovery.uniqueSorted(builtIn + miseRoots)
    }

    /// Synchronous allowlist check used by `SafetyPolicy`: `url` must sit under an allowed root
    /// and match a project cache rule (including its `beside` marker).
    static func isAllowedScope(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               rules: ProjectCacheRules? = nil,
                               miseEnv: MiseProjectDiscovery.Environment? = nil) -> Bool {
        let url = CleanupPath.fileURL(url)
        let activeRules = rules ?? ProjectCacheRulesLoader.current(home: home)
        return discoveryRoots(home: home, miseEnv: miseEnv).contains { root in
            activeRules.matchDirectory(url, under: root) != nil
        }
    }

    /// Scans allowed project discovery roots for Git repositories and returns validated cache candidates.
    static func candidates(activity: CleanupActivity, now: Date = Date(),
                           home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           roots: [URL]? = nil,
                           rules: ProjectCacheRules? = nil,
                           minimumBytes: Int64 = defaultMinimumBytes,
                           claudeProjectsDirectory: URL? = nil,
                           miseEnv: MiseProjectDiscovery.Environment? = nil,
                           git: WorktreeGitProcess = WorktreeGitProcess()) -> [CleanupCandidate] {
        let activeRules = rules ?? ProjectCacheRulesLoader.current(home: home)
        let searchRoots = (roots ?? discoveryRoots(home: home, miseEnv: miseEnv)).map(CleanupPath.fileURL)
        let projectRoots = discoverGitProjects(under: searchRoots, git: git)
        let claudeDir = claudeProjectsDirectory ?? defaultClaudeProjectsDirectory(home: home)
        let claudeFolders = listSubdirectories(claudeDir)
        var results: [CleanupCandidate] = []
        var seen = Set<String>()
        for project in projectRoots {
            guard !Task.isCancelled else { break }
            let found = scanProject(project, activity: activity, now: now, home: home, rules: activeRules,
                                    minimumBytes: minimumBytes, claudeDir: claudeDir,
                                    claudeFolders: claudeFolders, git: git)
            for candidate in found where seen.insert(candidate.url.path).inserted {
                results.append(candidate)
            }
        }
        return results
    }

    /// Scans one Git project root for disposable caches.
    static func scanProject(_ projectRoot: URL, activity: CleanupActivity, now: Date = Date(),
                            home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            rules: ProjectCacheRules = .default,
                            minimumBytes: Int64 = defaultMinimumBytes,
                            claudeDir: URL? = nil,
                            claudeFolders: [String]? = nil,
                            git: WorktreeGitProcess = WorktreeGitProcess()) -> [CleanupCandidate] {
        let root = CleanupPath.fileURL(projectRoot)
        guard TemporaryBuildOutput.isRealDirectory(root),
              let defaultRepo = gitWorkTreeTopLevel(for: root, git: git) else { return [] }
        let (matched, nestedRepos) = walkProject(root: root, rules: rules)
        guard !matched.isEmpty else { return [] }

        let resolvedClaudeDir = claudeDir ?? defaultClaudeProjectsDirectory(home: home)
        let folders = claudeFolders ?? listSubdirectories(resolvedClaudeDir)
        var activityByRepo: [String: Date?] = [:]
        func owningActivity(for repo: URL) -> Date? {
            if let cached = activityByRepo[repo.path] { return cached }
            let computed = projectLastActivity(root: repo, claudeDir: resolvedClaudeDir,
                                               claudeFolders: folders, git: git)
            activityByRepo[repo.path] = computed
            return computed
        }

        var candidates: [CleanupCandidate] = []
        for (url, match) in matched {
            guard !Task.isCancelled, !activity.contains(url) else { continue }
            let repo = innermostRepo(for: url, root: defaultRepo, nestedRepos: nestedRepos)
            guard let lastActivity = owningActivity(for: repo),
                  isQuiet(lastActivity: lastActivity, now: now, quietHours: rules.quietHours) else { continue }
            guard (try? verifyGitIgnoredAndUntracked(cacheURL: url, repoRoot: repo, git: git)) != nil else { continue }
            guard (try? ProjectCacheRules.refuseInsideViolation(in: url, patterns: match.refuseInside)) == nil else { continue }
            guard let survey = try? FolderSurvey.read(url, gitAllowedUnder: []),
                  survey.bytes >= minimumBytes,
                  survey.idle(at: now) >= rules.quietHours * 3_600,
                  let identity = fileIdentity(of: url) else { continue }

            let name = url.path.hasPrefix(home.path + "/") ? String(url.path.dropFirst(home.path.count + 1)) : url.path
            let idleHours = Int(min(now.timeIntervalSince(lastActivity), survey.idle(at: now)) / 3_600)
            let age = idleHours >= 48 ? "\(idleHours / 24) days" : "\(idleHours) hours"
            let candidate = CleanupCandidate(
                url: url, name: name, category: .cache, size: survey.bytes, risk: .low,
                reason: "Git-ignored project cache (\(match.label)) with no tracked files, no nested repositories, and no project activity for \(age).",
                identity: identity, deletionMode: .projectCache
            )
            guard (try? SafetyPolicy(home: home, now: now).validate(candidate)) != nil else { continue }
            candidates.append(candidate)
        }
        return candidates
    }

    /// Re-verifies every safety invariant right before `SecureFileDeleter` removes the cache directory.
    static func verifyBeforeDeletion(_ candidate: CleanupCandidate, activity: CleanupActivity,
                                     now: Date = Date(),
                                     home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                     rules: ProjectCacheRules? = nil,
                                     claudeProjectsDirectory: URL? = nil,
                                     git: WorktreeGitProcess = WorktreeGitProcess()) throws {
        let activeRules = rules ?? ProjectCacheRulesLoader.current(home: home)
        let url = CleanupPath.fileURL(candidate.url)
        guard candidate.deletionMode == .projectCache, TemporaryBuildOutput.isRealDirectory(url) else {
            throw SafetyPolicyError.refused("The project cache no longer exists as a directory. Scan again.")
        }
        try activity.requireIdle(url)

        let parent = url.deletingLastPathComponent()
        let topLevel = try git.text(parent.path, ["rev-parse", "--show-toplevel"])
        guard !topLevel.isEmpty else {
            throw SafetyPolicyError.refused("The project cache is no longer inside a Git repository.")
        }
        let repoRoot = CleanupPath.fileURL(URL(fileURLWithPath: topLevel, isDirectory: true))
        guard let match = activeRules.matchDirectory(url, under: repoRoot) else {
            throw SafetyPolicyError.refused("The folder no longer matches a project cache rule. Scan again.")
        }

        let claudeDir = claudeProjectsDirectory ?? defaultClaudeProjectsDirectory(home: home)
        let claudeFolders = listSubdirectories(claudeDir)
        guard let lastActivity = projectLastActivity(root: repoRoot, claudeDir: claudeDir,
                                                     claudeFolders: claudeFolders, git: git),
              isQuiet(lastActivity: lastActivity, now: now, quietHours: activeRules.quietHours) else {
            throw FeatureFailure(message: "The project became active after the scan. Nothing was deleted.")
        }

        try verifyGitIgnoredAndUntracked(cacheURL: url, repoRoot: repoRoot, git: git)
        if let violation = try ProjectCacheRules.refuseInsideViolation(in: url, patterns: match.refuseInside) {
            throw SafetyPolicyError.refused("Refused project cache containing \(violation).")
        }
        let survey = try FolderSurvey.read(url, gitAllowedUnder: [])
        guard survey.idle(at: now) >= activeRules.quietHours * 3_600 else {
            throw FeatureFailure(message: "The project cache changed recently. Scan again after it is quiet.")
        }
    }

    static func discoverGitProjects(under roots: [URL], git: WorktreeGitProcess = WorktreeGitProcess()) -> [URL] {
        var found: [URL] = [], seen = Set<String>()
        for root in roots where TemporaryBuildOutput.isRealDirectory(root) {
            if hasGitEntry(root) || gitWorkTreeTopLevel(for: root, git: git) != nil {
                if seen.insert(root.path).inserted { found.append(root) }
                continue
            }
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            var folders = 0
            for case let rawURL as URL in walker {
                if Task.isCancelled { return found }
                guard let values = try? rawURL.resourceValues(forKeys: keys),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                folders += 1
                if folders > discoveryDirectoryLimit { break }
                let url = CleanupPath.fileURL(rawURL)
                let depth = url.pathComponents.count - root.pathComponents.count
                if depth > discoveryDepthLimit || !TemporaryBuildOutput.isRealDirectory(url) {
                    walker.skipDescendants(); continue
                }
                if hasGitEntry(url) {
                    if seen.insert(url.path).inserted { found.append(url) }
                    walker.skipDescendants(); continue
                }
                if ProjectCacheRules.default.skip.contains(url.lastPathComponent) || url.lastPathComponent == "node_modules" {
                    walker.skipDescendants()
                }
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    static func encodeClaudeFolder(_ path: String) -> String {
        String(path.map { ch -> Character in
            guard ch.isASCII, ch.isLetter || ch.isNumber else { return "-" }
            return ch
        })
    }

    private static func walkProject(root: URL, rules: ProjectCacheRules) -> ([(URL, ProjectCacheRules.Match)], [URL]) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: { _, _ in true }) else { return ([], []) }
        var matched: [(URL, ProjectCacheRules.Match)] = []
        var nestedRepos: [URL] = []
        var folders = 0
        for case let rawURL as URL in walker {
            if Task.isCancelled { return ([], []) }
            guard let values = try? rawURL.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            folders += 1
            if folders > projectWalkDirectoryLimit { break }
            let url = CleanupPath.fileURL(rawURL)
            guard TemporaryBuildOutput.isRealDirectory(url), url.path.hasPrefix(root.path + "/") else {
                walker.skipDescendants(); continue
            }
            if rules.skip.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if let hit = rules.match(relativePath: relative, hasMarker: { holderRel, marker in
                let holder = holderRel.isEmpty ? root : root.appending(path: holderRel, directoryHint: .isDirectory)
                return ProjectCacheRules.directoryHasEntry(holder, matching: marker)
            }) {
                matched.append((url, hit))
                walker.skipDescendants()
                continue
            }
            if hasGitEntry(url) { nestedRepos.append(url) }
        }
        return (matched, nestedRepos)
    }

    private static func innermostRepo(for url: URL, root: URL, nestedRepos: [URL]) -> URL {
        var best = root
        for repo in nestedRepos where url.path.hasPrefix(repo.path + "/") && repo.path.count > best.path.count {
            best = repo
        }
        return best
    }

    private static func verifyGitIgnoredAndUntracked(cacheURL: URL, repoRoot: URL, git: WorktreeGitProcess) throws {
        guard cacheURL.path.hasPrefix(repoRoot.path + "/") else {
            throw SafetyPolicyError.refused("Project cache is outside its repository root.")
        }
        let rel = String(cacheURL.path.dropFirst(repoRoot.path.count + 1))
        // `git check-ignore` requires `--stdin` with `-z` and rejects GIT_LITERAL_PATHSPECS=1.
        let ignored = try git.run(repoRoot.path, ["check-ignore", "--stdin", "-z"], allowed: [0, 1],
                                  input: Data((rel + "\0").utf8))
        let ignoredPaths = ignored.data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard ignored.code == 0, ignoredPaths.contains(rel) else {
            throw SafetyPolicyError.refused("Project cache \(rel) is not ignored by Git.")
        }
        let tracked = try git.run(repoRoot.path, ["ls-files", "-z", "--", rel],
                                  environment: ["GIT_LITERAL_PATHSPECS": "1"])
        guard tracked.data.isEmpty else {
            throw SafetyPolicyError.refused("Project cache \(rel) contains tracked Git files.")
        }
    }

    private static func projectLastActivity(root: URL, claudeDir: URL, claudeFolders: [String],
                                            git: WorktreeGitProcess) -> Date? {
        guard let output = try? git.text(root.path, ["rev-parse", "--show-toplevel", "--git-path", "logs/HEAD", "--git-path", "HEAD"]) else {
            return nil
        }
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count == 3 else { return nil }
        var newest: Date?
        for candidate in lines.dropFirst() {
            let full = candidate.hasPrefix("/") ? candidate : root.appending(path: candidate).path
            var info = stat()
            if stat(full, &info) == 0 {
                newest = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
                break
            }
        }
        guard var latest = newest else { return nil }
        if let claudeTime = newestClaudeTranscript(for: root, claudeDir: claudeDir, claudeFolders: claudeFolders),
           claudeTime > latest {
            latest = claudeTime
        }
        return latest
    }

    private static func newestClaudeTranscript(for root: URL, claudeDir: URL, claudeFolders: [String]) -> Date? {
        guard !claudeFolders.isEmpty else { return nil }
        var keys = [encodeClaudeFolder(root.path)]
        if let resolved = realpath(root.path, nil) {
            let real = String(cString: resolved)
            free(resolved)
            let encoded = encodeClaudeFolder(real)
            if !keys.contains(encoded) { keys.append(encoded) }
        }
        let matching = claudeFolders.filter { name in
            keys.contains { key in name == key || name.hasPrefix(key + "-") }
        }
        var newest: Date?
        for folder in matching {
            let dir = claudeDir.appending(path: folder, directoryHint: .isDirectory)
            guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [], errorHandler: { _, _ in true }) else { continue }
            for case let file as URL in walker where file.pathExtension == "jsonl" {
                var info = stat()
                if stat(file.path, &info) == 0 {
                    let mod = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
                    if newest == nil || mod > newest! { newest = mod }
                }
            }
        }
        return newest
    }

    private static func isQuiet(lastActivity: Date, now: Date, quietHours: Double) -> Bool {
        now.timeIntervalSince(lastActivity) >= quietHours * 3_600
    }

    private static func defaultClaudeProjectsDirectory(home: URL) -> URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return CleanupPath.fileURL(URL(fileURLWithPath: custom, isDirectory: true)).appending(path: "projects", directoryHint: .isDirectory)
        }
        return CleanupPath.fileURL(home).appending(path: ".claude/projects", directoryHint: .isDirectory)
    }

    private static func listSubdirectories(_ dir: URL) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return entries.filter { name in
            var info = stat()
            return stat(dir.appending(path: name).path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
        }
    }

    private static func hasGitEntry(_ dir: URL) -> Bool {
        var info = stat()
        return lstat(dir.appending(path: ".git").path, &info) == 0
    }

    private static func gitWorkTreeTopLevel(for dir: URL, git: WorktreeGitProcess) -> URL? {
        guard let top = try? git.text(dir.path, ["rev-parse", "--show-toplevel"]), !top.isEmpty else { return nil }
        return CleanupPath.fileURL(URL(fileURLWithPath: top, isDirectory: true))
    }

    private static func fileIdentity(of url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}
