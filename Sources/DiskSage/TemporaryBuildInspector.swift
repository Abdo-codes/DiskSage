import Darwin
import Foundation

/// Turns temporary build output into whole-folder candidates, and checks them again before deletion.
enum TemporaryBuildInspector {
    struct ScanResult {
        var candidates: [CleanupCandidate] = []
        /// Discovered build folders that stay with the generated-file rule.
        var generatedRoots: [URL] = []
    }

    /// Sorts discovered build folders and adds loose bundles and stale scratchpads.
    /// Nothing inside a live Claude session is offered, not even compiled files.
    static func scan(discovered: [URL], activity: CleanupActivity, now: Date = Date(),
                     home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     extraFolders: () -> [URL] = { looseBundles() + ClaudeSessionActivity.scratchpads() + AgentWorkspaceDiscovery.folders() }) -> ScanResult {
        let sessions = ClaudeSessionActivity.Cache(activity: activity, now: now)
        var result = ScanResult()
        for url in discovered where !Task.isCancelled && !sessions.isInsideLiveSession(url) {
            if TemporaryBuildOutput.kind(of: url, home: home) == .derivedData,
               let candidate = inspect(url, activity: activity, now: now, home: home) {
                result.candidates.append(candidate)
            } else {
                // Too new for a whole-folder offer: older compiled files can still go.
                result.generatedRoots.append(url)
            }
        }
        for url in extraFolders() where !Task.isCancelled && !sessions.isInsideLiveSession(url) {
            if let candidate = inspect(url, activity: activity, now: now, home: home) { result.candidates.append(candidate) }
        }
        var unique = Set<String>()
        result.candidates.removeAll { !unique.insert(CleanupPath.fileURL($0.url).path).inserted }
        // A whole folder already covers everything inside it: offer each file once.
        let wholes = result.candidates.map { CleanupPath.fileURL($0.url).path }
        func covered(_ url: URL) -> Bool {
            let path = CleanupPath.fileURL(url).path
            return wholes.contains { path.hasPrefix($0 + "/") }
        }
        result.candidates.removeAll { covered($0.url) }
        result.generatedRoots.removeAll(where: covered)
        return result
    }

    /// A whole-folder candidate, or nil when the folder is in use, too new, holds Git data, or fails the policy.
    static func inspect(_ url: URL, activity: CleanupActivity, now: Date = Date(),
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> CleanupCandidate? {
        let url = CleanupPath.fileURL(url)
        guard let kind = TemporaryBuildOutput.kind(of: url, home: home), !activity.contains(url),
              let survey = try? survey(url, kind: kind), survey.bytes > 0,
              let risk = TemporaryBuildOutput.risk(kind, idle: survey.idle(at: now)) else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let name = url.path.hasPrefix(home.path + "/") ? String(url.path.dropFirst(home.path.count + 1)) : url.path
        let candidate = CleanupCandidate(url: url, name: name, category: TemporaryBuildOutput.category(kind),
            size: survey.bytes, risk: risk, reason: TemporaryBuildOutput.reason(kind, idle: survey.idle(at: now)),
            identity: FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)), deletionMode: .item)
        guard (try? SafetyPolicy(home: home, now: now).validate(candidate)) != nil else { return nil }
        return candidate
    }

    /// Runs again right before deletion: the kind, the session, the age and the Git check must all still hold.
    static func verifyBeforeDeletion(_ candidate: CleanupCandidate, activity: CleanupActivity, now: Date = Date(),
                                     home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let url = CleanupPath.fileURL(candidate.url)
        guard let kind = TemporaryBuildOutput.kind(of: url, home: home) else {
            throw FeatureFailure(message: "The folder no longer looks like build output. Scan again.")
        }
        try activity.requireIdle(url)
        if let session = ClaudeSessionActivity.session(containing: url),
           ClaudeSessionActivity.isLive(session, activity: activity, now: now) {
            throw FeatureFailure(message: "A Claude session still uses this folder. Nothing was deleted.")
        }
        let current = try survey(url, kind: kind)
        guard let risk = TemporaryBuildOutput.risk(kind, idle: current.idle(at: now)), risk <= candidate.risk else {
            throw FeatureFailure(message: "The folder changed after the scan. Scan again.")
        }
    }

    /// `.xcresult` and `.app` bundles directly in /private/tmp, or one folder down.
    static func looseBundles(in root: URL = TemporaryBuildOutput.temporaryRoot) -> [URL] {
        let manager = FileManager.default
        func children(_ folder: URL) -> [URL] {
            ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? []).map { folder.appending(path: $0) }
        }
        let claude = TemporaryBuildOutput.claudeRoot.path
        var result: [URL] = []
        for child in children(root) where child.path != claude && TemporaryBuildOutput.isRealDirectory(child) {
            if isBundleName(child) { result.append(child); continue }
            result += children(child).filter { isBundleName($0) && TemporaryBuildOutput.isRealDirectory($0) }
        }
        return result.map(CleanupPath.fileURL)
    }

    private static func isBundleName(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".xcresult") || name.hasSuffix(".app")
    }

    private static func survey(_ url: URL, kind: TemporaryBuildOutput.Kind) throws -> FolderSurvey {
        try FolderSurvey.read(url, gitAllowedUnder: TemporaryBuildOutput.gitAllowedUnder(kind))
    }
}
