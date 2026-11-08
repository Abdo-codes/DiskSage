import Darwin
import Foundation

enum WorktreePathGuard {
    static func identity(_ path: String) throws -> String {
        let url = CleanupPath.fileURL(URL(fileURLWithPath: path))
        guard url.path == path else { throw FeatureFailure(message: "Noncanonical checkout path.") }
        var current = URL(fileURLWithPath: "/"), info = stat()
        for part in url.pathComponents.dropFirst() {
            current.append(path: part)
            guard lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid() || current.pathComponents.count < 4 else {
                throw FeatureFailure(message: "Checkout path is missing, symlinked, or owned by another user.")
            }
        }
        return "\(info.st_dev):\(info.st_ino)"
    }
    static func contains(_ parent: String, _ child: String) -> Bool { child == parent || child.hasPrefix(parent + "/") }

    /// Also used at generic deletion execution; no discovered source root becomes an allowlisted cache.
    static func rejectSourceContainers(_ folder: URL) throws {
        let manager = FileManager.default
        let root = CleanupPath.fileURL(folder)
        guard manager.fileExists(atPath: root.path) else { return }
        var failed = false
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [], errorHandler: { _, _ in failed = true; return false }) else {
            throw FeatureFailure(message: "Cannot verify that the cleanup folder excludes Git checkouts.")
        }
        if manager.fileExists(atPath: root.appending(path: ".git").path) ||
            manager.fileExists(atPath: root.appending(path: "HEAD").path) && manager.fileExists(atPath: root.appending(path: "objects").path) {
            throw FeatureFailure(message: "Git checkout roots and repository data require Git Worktrees review. Choose a generated child folder instead.")
        }
        var count = 0
        for case let url as URL in walker {
            count += 1
            guard count <= 200_000, !Task.isCancelled else { throw FeatureFailure(message: "Folder is too large to verify safely for nested Git checkouts.") }
            if url.lastPathComponent.lowercased() == ".git" || (url.lastPathComponent == "HEAD" && manager.fileExists(atPath: url.deletingLastPathComponent().appending(path: "objects").path)) {
                throw FeatureFailure(message: "Folder contains Git checkout or repository data. Choose a generated child folder instead.")
            }
            // This enumerator does not follow symlinks. Calling skipDescendants on a link/file
            // can skip the next real directory and miss a nested source repository on macOS.
        }
        guard !failed else { throw FeatureFailure(message: "Some folders could not be checked for nested Git checkouts.") }
    }
}
