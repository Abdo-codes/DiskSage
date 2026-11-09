import Darwin
import Foundation

/// Claude Code keeps one temporary folder per session:
/// `/private/tmp/claude-<uid>/<project>/<session>/`, with `scratchpad/` and `tasks/` in it.
/// A session can resume at any time, so DiskSage treats a session as live while
/// a process uses its folder or anything in it changed during the last day.
enum ClaudeSessionActivity {
    static let liveWindow: TimeInterval = TemporaryBuildOutput.day

    /// The session folder that holds `url`, or nil when `url` is not inside one.
    static func session(containing url: URL) -> URL? {
        let parts = CleanupPath.fileURL(url).pathComponents
        let root = TemporaryBuildOutput.claudeRoot.pathComponents
        guard parts.starts(with: root), parts.count >= root.count + 2 else { return nil }
        return URL(fileURLWithPath: "/" + parts.dropFirst().prefix(root.count + 1).joined(separator: "/"), isDirectory: true)
    }

    /// Live sessions keep every file, also compiled files. When the check cannot finish, the session is live.
    static func isLive(_ session: URL, activity: CleanupActivity, now: Date) -> Bool {
        if activity.contains(session) { return true }
        guard let survey = try? FolderSurvey.read(session, gitAllowedUnder: nil) else { return true }
        return survey.idle(at: now) < liveWindow
    }

    /// Every session scratchpad that the current user owns. Links are never followed.
    static func scratchpads() -> [URL] {
        let manager = FileManager.default
        let root = TemporaryBuildOutput.claudeRoot
        guard TemporaryBuildOutput.isRealDirectory(root),
              let projects = try? manager.contentsOfDirectory(atPath: root.path) else { return [] }
        var result: [URL] = []
        for project in projects {
            let projectURL = root.appending(path: project, directoryHint: .isDirectory)
            guard TemporaryBuildOutput.isRealDirectory(projectURL),
                  let sessions = try? manager.contentsOfDirectory(atPath: projectURL.path) else { continue }
            for session in sessions {
                let scratchpad = projectURL.appending(path: "\(session)/scratchpad", directoryHint: .isDirectory)
                if TemporaryBuildOutput.isRealDirectory(projectURL.appending(path: session)),
                   TemporaryBuildOutput.isRealDirectory(scratchpad) {
                    result.append(CleanupPath.fileURL(scratchpad))
                }
            }
        }
        return result
    }

    /// Caches one answer per session during one scan.
    final class Cache {
        private let activity: CleanupActivity
        private let now: Date
        private var answers: [String: Bool] = [:]
        init(activity: CleanupActivity, now: Date) { self.activity = activity; self.now = now }

        /// True when `url` is inside a live session.
        func isInsideLiveSession(_ url: URL) -> Bool {
            guard let session = ClaudeSessionActivity.session(containing: url) else { return false }
            if let known = answers[session.path] { return known }
            let live = ClaudeSessionActivity.isLive(session, activity: activity, now: now)
            answers[session.path] = live
            return live
        }
    }
}
