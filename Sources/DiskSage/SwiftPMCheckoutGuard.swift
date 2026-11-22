import Darwin
import Foundation

/// Verifies that SwiftPM clones inside `SourcePackages` or a SwiftPM scratch folder
/// contain no local edits, stashes, local-only commits, or unexpected Git repositories.
/// Anything SwiftPM cannot recreate cleanly stops whole-folder deletion.
enum SwiftPMCheckoutGuard {
    private struct MirrorInfo {
        let realPath: String
        let tags: [String: String]
    }

    static func verify(_ root: URL, kind: TemporaryBuildOutput.Kind,
                       git: WorktreeGitProcess = WorktreeGitProcess(),
                       maximumEntries: Int = 200_000) throws {
        let container: URL
        switch kind {
        case .derivedData, .xcodeProjectBuild:
            container = CleanupPath.fileURL(root).appending(path: "SourcePackages", directoryHint: .isDirectory)
        case .swiftPackages:
            container = CleanupPath.fileURL(root)
        default:
            return
        }
        guard TemporaryBuildOutput.isRealDirectory(container) else { return }

        let (mirrors, checkouts) = try discoverManagedRepos(in: container, maximumEntries: maximumEntries)
        var verifiedMirrors: [MirrorInfo] = []
        for mirror in mirrors {
            verifiedMirrors.append(try verifyMirror(mirror, git: git))
        }
        for checkout in checkouts {
            try verifyCheckout(checkout, mirrors: verifiedMirrors, git: git)
        }
    }

    private static func discoverManagedRepos(in container: URL, maximumEntries: Int) throws -> (mirrors: [URL], checkouts: [URL]) {
        let checkoutsDir = container.appending(path: "checkouts", directoryHint: .isDirectory).path
        let repositoriesDir = container.appending(path: "repositories", directoryHint: .isDirectory).path
        let manager = FileManager.default
        var failed = false, visited = 0
        guard let walker = manager.enumerator(at: container, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [], errorHandler: { _, _ in failed = true; return false }) else {
            throw FeatureFailure(message: "Could not inspect SwiftPM repositories.")
        }

        var mirrors: [URL] = [], checkouts: [URL] = []
        var seenMirrors = Set<String>(), seenCheckouts = Set<String>()
        for case let rawURL as URL in walker {
            try Task.checkCancellation()
            visited += 1
            guard visited <= maximumEntries else {
                throw FeatureFailure(message: "SwiftPM repository inspection exceeded its safety limit.")
            }
            let url = CleanupPath.fileURL(rawURL)
            let name = url.lastPathComponent
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw FeatureFailure(message: "Could not inspect \(url.path) inside SwiftPM cache.")
            }
            let isDir = (info.st_mode & S_IFMT) == S_IFDIR
            let isReg = (info.st_mode & S_IFMT) == S_IFREG

            if name.lowercased() == ".git" {
                let repo = url.deletingLastPathComponent()
                // Only a real .git directory directly inside checkouts/<pkg> is managed by SwiftPM.
                guard isDir, repo.deletingLastPathComponent().path == checkoutsDir else {
                    throw FeatureFailure(message: "Unexpected Git repository inside SwiftPM cache: \(repo.lastPathComponent).")
                }
                if seenCheckouts.insert(repo.path).inserted { checkouts.append(repo) }
                continue
            }

            if name == "HEAD", isReg {
                let parent = url.deletingLastPathComponent()
                if sharesGitDir(parent) {
                    throw FeatureFailure(message: "Linked Git directory found inside SwiftPM cache: \(parent.lastPathComponent).")
                }
                let hasObjects = isRealDir(parent.appending(path: "objects"))
                let hasRefs = isRealDir(parent.appending(path: "refs"))
                guard hasObjects && hasRefs else { continue }
                if parent.lastPathComponent == ".git", parent.deletingLastPathComponent().deletingLastPathComponent().path == checkoutsDir {
                    continue
                }
                guard parent.deletingLastPathComponent().path == repositoriesDir else {
                    throw FeatureFailure(message: "Unexpected Git directory inside SwiftPM cache: \(parent.lastPathComponent).")
                }
                if seenMirrors.insert(parent.path).inserted { mirrors.append(parent) }
            }
        }
        guard !failed else { throw FeatureFailure(message: "Some folders inside SwiftPM cache could not be read.") }
        return (mirrors.sorted { $0.path < $1.path }, checkouts.sorted { $0.path < $1.path })
    }

    private static func verifyMirror(_ mirror: URL, git: WorktreeGitProcess) throws -> MirrorInfo {
        let dir = mirror.path
        let base = ["--git-dir=\(dir)"]
        guard try git.text(dir, base + ["rev-parse", "--is-bare-repository"]) == "true" else {
            throw FeatureFailure(message: "SwiftPM repository \(mirror.lastPathComponent) is not bare.")
        }
        try rejectWorktrees(gitDir: mirror)
        guard try git.text(dir, base + ["remote"]) == "origin" else {
            throw FeatureFailure(message: "SwiftPM repository \(mirror.lastPathComponent) does not have only origin.")
        }
        guard try git.text(dir, base + ["config", "--bool", "--get", "remote.origin.mirror"], allowed: [0, 1]) == "true" else {
            throw FeatureFailure(message: "SwiftPM repository \(mirror.lastPathComponent) is not a mirror of origin.")
        }
        guard try git.text(dir, base + ["rev-list", "-n", "1", "--reflog", "--not", "--all"]).isEmpty else {
            throw FeatureFailure(message: "SwiftPM repository \(mirror.lastPathComponent) has reflog-only commits.")
        }
        let tags = try tagRefs(dir: dir, baseArgs: base, git: git)
        guard let real = realPath(dir) else {
            throw FeatureFailure(message: "Could not resolve SwiftPM mirror path.")
        }
        return MirrorInfo(realPath: real, tags: tags)
    }

    private static func verifyCheckout(_ checkout: URL, mirrors: [MirrorInfo], git: WorktreeGitProcess) throws {
        let dir = checkout.path
        let gitDir = checkout.appending(path: ".git")
        try rejectWorktrees(gitDir: gitDir)
        let base = ["--git-dir=\(gitDir.path)", "--work-tree=\(dir)"]
        try git.rejectHelpers(dir)

        // Refuse any stash.
        let stash = try git.run(dir, base + ["rev-parse", "--verify", "--quiet", "refs/stash"], allowed: [0, 1])
        guard stash.code == 1 else {
            throw FeatureFailure(message: "SwiftPM checkout \(checkout.lastPathComponent) has a stash.")
        }
        // Refuse changed, untracked, or ignored files.
        let status = try git.run(dir, base + ["status", "--porcelain=v1", "-z", "--untracked-files=all",
                                              "--ignored=matching", "--ignore-submodules=none"])
        guard status.data.isEmpty else {
            throw FeatureFailure(message: "SwiftPM checkout \(checkout.lastPathComponent) has local changes or untracked files.")
        }
        // Refuse assume-unchanged, skip-worktree, or unverified submodules.
        let blockers = try git.indexBlockers(dir)
        guard blockers.isEmpty else {
            throw FeatureFailure(message: "SwiftPM checkout \(checkout.lastPathComponent): \(blockers[0])")
        }
        // Require a single origin pointing to one of the verified mirrors in this cache.
        guard try git.text(dir, base + ["remote"]) == "origin" else {
            throw FeatureFailure(message: "SwiftPM checkout \(checkout.lastPathComponent) does not have only origin.")
        }
        let rawOrigin = try git.run(dir, base + ["config", "-z", "--get-all", "remote.origin.url"]).data
        let urls = rawOrigin.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard urls.count == 1, let originURL = urls.first, originURL.hasPrefix("/"),
              let resolvedOrigin = realPath(originURL),
              let mirror = mirrors.first(where: { $0.realPath == resolvedOrigin }) else {
            throw FeatureFailure(message: "SwiftPM checkout \(checkout.lastPathComponent) origin is not a verified SwiftPM mirror.")
        }
        // Refuse any commit pushed from the checkout into the mirror.
        let pushLog = try git.text(dir, base + ["log", "-g", "--format=%gs", "--glob=refs/remotes/origin/*"])
        guard !pushLog.split(separator: "\n").contains(where: { $0.hasPrefix("update by push") }) else {
            throw FeatureFailure(message: "SwiftPM checkout \(checkout.lastPathComponent) pushed commits to its mirror.")
        }
        // Refuse any commit held only by HEAD, local branches, local-only tags, or reflogs.
        let checkoutTags = try tagRefs(dir: dir, baseArgs: base, git: git)
        var revArgs = base + ["rev-list", "-n", "1", "--all", "--reflog", "--not", "--glob=refs/remotes/origin/*"]
        for (name, oid) in checkoutTags where mirror.tags[name] == oid {
            revArgs.append(oid)
        }
        guard try git.text(dir, revArgs).isEmpty else {
            throw FeatureFailure(message: "SwiftPM checkout \(checkout.lastPathComponent) has local-only commits.")
        }
    }

    private static func tagRefs(dir: String, baseArgs: [String], git: WorktreeGitProcess) throws -> [String: String] {
        let output = try git.text(dir, baseArgs + ["for-each-ref", "--format=%(objectname) %(refname)", "refs/tags"])
        var tags: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { tags[String(parts[1])] = String(parts[0]) }
        }
        return tags
    }

    private static func rejectWorktrees(gitDir: URL) throws {
        var info = stat()
        if lstat(gitDir.appending(path: "worktrees").path, &info) == 0 {
            throw FeatureFailure(message: "SwiftPM repository has linked worktrees.")
        }
        guard errno == ENOENT else {
            throw FeatureFailure(message: "Could not check SwiftPM repository for linked worktrees.")
        }
    }

    private static func sharesGitDir(_ dir: URL) -> Bool {
        var info = stat()
        return lstat(dir.appending(path: "commondir").path, &info) == 0 ||
            lstat(dir.appending(path: "gitdir").path, &info) == 0
    }

    private static func isRealDir(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
