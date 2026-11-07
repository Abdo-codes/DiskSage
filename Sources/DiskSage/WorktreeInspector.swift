import Foundation

struct WorktreeInspector: Sendable {
    var git = WorktreeGitProcess()
    var checkActivity = true
    var processPaths: [String]?
    enum SharedObjectCheck: Sendable { case passed, failed(FeatureFailure) }
    var sharedObjectChecks: [String: SharedObjectCheck] = [:]

    func inspect(_ worktree: GitWorktree, configuration: WorktreeConfiguration) -> WorktreeInspection {
        var value = WorktreeInspection(worktree: worktree)
        do {
            let path = worktree.path
            if worktree.main { value.blockers.append("Main checkout cannot be removed.") }
            if worktree.locked { value.blockers.append("Git worktree is locked.") }
            if worktree.missing { value.blockers.append("Missing registration: metadata only; no disk savings claimed."); return value }
            if configuration.protectedIDs.contains(value.id) { value.blockers.append("Kept by DiskSage protection.") }
            if !configuration.roots.contains(where: { WorktreePathGuard.contains($0, path) }) { value.blockers.append("Outside approved folders. Add its folder explicitly.") }
            let identity = try WorktreePathGuard.identity(path)
            let marker = URL(fileURLWithPath: path + "/.git")
            guard try marker.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw FeatureFailure(message: "Symlinked Git administrative pointer is unsupported.")
            }
            let common = try git.text(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
            guard common == worktree.commonDirectory else { throw FeatureFailure(message: "Repository identity changed.") }
            let commonIdentity = try WorktreePathGuard.identity(common)
            if !worktree.main {
                guard !WorktreePathGuard.contains(path, common) else { throw FeatureFailure(message: "Shared Git data is inside this checkout; removal is unsupported.") }
                switch sharedObjectChecks[common] {
                case .passed: break
                case let .failed(error): throw error
                case nil: try WorktreeObjectPolicy.validate(common: common, checkout: path)
                }
            }
            try git.rejectHelpers(path)
            guard try git.text(path, ["rev-parse", "--path-format=absolute", "--show-toplevel"]) == path else {
                throw FeatureFailure(message: "Git's effective checkout root differs from the registered path.")
            }
            guard try git.text(path, ["rev-parse", "--is-shallow-repository"]) == "false" else {
                throw FeatureFailure(message: "Shallow history cannot establish preservation.")
            }
            let admin = try git.text(path, ["rev-parse", "--absolute-git-dir"])
            let adminIdentity = try WorktreePathGuard.identity(admin)
            let head = try git.text(path, ["rev-parse", "--verify", "HEAD^{commit}"])
            guard head == worktree.head else { throw FeatureFailure(message: "HEAD changed during discovery. Refresh.") }
            try WorktreeGitConfiguration.validateLocalFile(git, path: path, admin: admin)
            let metadata = try WorktreeMetadata.inspect(admin: admin, common: common)
            value.removalWarnings = metadata.warnings
            let index = try git.run(path, ["ls-files", "-v", "--stage", "-z"]).text.components(separatedBy: "\0").filter { !$0.isEmpty }
            if index.contains(where: { $0.first?.isLowercase == true || $0.first == "S" }) {
                value.blockers.append("Index has assume-unchanged or skip-worktree entries.")
            }
            if index.contains(where: { $0.dropFirst(2).hasPrefix("160000 ") }) { value.blockers.append("Submodules are unsupported.") }
            try WorktreeParsing.status(git.run(path, ["status", "--porcelain=v2", "-z", "--untracked-files=normal", "--ignored=matching", "--ignore-submodules=none"]).data, into: &value)
            if !value.staged.isEmpty || !value.modified.isEmpty || !value.conflicted.isEmpty || !value.untracked.isEmpty {
                value.removalWarnings?.append("Uncommitted staged, modified, conflicted and untracked files will be permanently deleted. Untracked directory entries include all their contents.")
            }
            let retained = try refs(path: path, into: &value, configuration: configuration, extraTips: metadata.tips)
            var draft = false
            if FileManager.default.fileExists(atPath: admin + "/COMMIT_EDITMSG") {
                let message = try String(contentsOfFile: admin + "/COMMIT_EDITMSG", encoding: .utf8).trimmingCharacters(in: .newlines)
                if message != (try git.text(path, ["log", "-1", "--format=%B", "HEAD"])) {
                    draft = true
                    value.removalWarnings?.append("Private draft commit message will be deleted: COMMIT_EDITMSG.")
                }
            }
            let ignored = try WorktreeIgnoredFiles.paths(git: git, checkout: path)
            let concerns = WorktreeValuePolicy.concerns(value, ignored: ignored, metadataDisposable: metadata.disposable, retained: retained, draft: draft)
            let manifest = try fileManifest(path: path, ignored: ignored)
            value.cleanupConcerns = concerns + (try WorktreeNestedPolicy.validate(manifest.nested, checkout: path, configuration: configuration, git: git, assessDisposable: concerns.isEmpty))
            value.estimatedBytes = manifest.bytes
            value.ignoredFiles = manifest.ignoredFiles
            value.removalWarnings?.append(contentsOf: manifest.nested.map { "Nested Git repository data will be deleted, including its branches and unsaved work: \($0)." })
            if checkActivity {
                let paths: [String]
                if let processPaths { paths = processPaths }
                else {
                    let output = try git.execute("/usr/sbin/lsof", ["-nP", "-d", "cwd,txt", "-F0pn"])
                    guard output.code == 0 else { throw FeatureFailure(message: "Process activity could not be checked.") }
                    paths = try WorktreeActivity.paths(output.data)
                }
                let active = paths.contains { WorktreePathGuard.contains(path, $0) }
                value.activity = "No matching process directory or executable observed; other editor/agent activity is unknown."
                if active { value.blockers.append("A process is using this checkout. Stop it before removal."); value.activity = "Known process activity observed." }
            }
            let pointer = (try? String(contentsOf: marker, encoding: .utf8)) ?? "main-directory"
            let evidence = [identity, pointer, commonIdentity, adminIdentity, admin, metadata.digest, manifest.digest,
                try git.text(path, ["show-ref"], allowed: [0, 1]),
                GitWorktree.digest(try git.run(path, ["config", "--null", "--list"]).text), value.integrationOID ?? "", value.integrationRef ?? "", value.activity,
                value.blockers.joined(separator: "\0"), value.discardReasons.joined(separator: "\0"), value.ignored.joined(separator: "\0"),
                (value.cleanupConcerns ?? []).joined(separator: "\0"),
                manifest.ignoredFiles.map { "\($0.path)\0\($0.estimatedBytes)\0\($0.symbolicLink)" }.joined(separator: "\n")].joined(separator: "\n")
            value.fingerprint = GitWorktree.digest(evidence)
        } catch { value.blockers.append(error.localizedDescription) }
        return value
    }

    private func refs(path: String, into value: inout WorktreeInspection, configuration: WorktreeConfiguration, extraTips: [String]) throws -> Bool {
        let shared = try git.text(path, ["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads", "refs/tags"])
        for line in shared.split(separator: "\n") {
            let pair = line.split(separator: " ", maxSplits: 1)
            guard pair.count == 2 else { throw FeatureFailure(message: "Incomplete shared reference.") }
            value.retainedRefs[String(pair[0])] = String(pair[1])
        }
        guard value.retainedRefs.count <= 500 else { throw FeatureFailure(message: "Too many shared references for bounded preservation review.") }
        let unretained = try git.text(path, ["rev-list", "--max-count=1", "HEAD", "--not", "--branches", "--tags"])
        if !unretained.isEmpty { value.removalWarnings?.append("Detached HEAD commits lack a retained local branch or tag and may become unrecoverable.") }
        var tips = Set(try git.text(path, ["reflog", "show", "--format=%H", "HEAD"]).split(separator: "\n").map(String.init))
        tips.formUnion(extraTips)
        let admin = try git.text(path, ["rev-parse", "--absolute-git-dir"])
        for name in ["ORIG_HEAD", "REBASE_HEAD", "FETCH_HEAD"] where FileManager.default.fileExists(atPath: admin + "/" + name) {
            let contents = try String(contentsOfFile: admin + "/" + name, encoding: .utf8)
            for line in contents.split(separator: "\n") { if let tip = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first { tips.insert(String(tip)) } }
        }
        guard tips.count <= 200 else { throw FeatureFailure(message: "Recovery history is too large to verify; preserve or review externally.") }
        guard tips.allSatisfy({ $0.utf8.count == value.worktree.head.utf8.count && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) } }) else {
            throw FeatureFailure(message: "Malformed recovery object ID; preservation could not be verified.")
        }
        let recoveryUnretained = try !tips.isEmpty && !git.text(path, ["rev-list", "--max-count=1"] + tips.sorted() + ["--not", "--branches", "--tags"]).isEmpty
        if recoveryUnretained {
            value.removalWarnings?.append("Worktree recovery history contains commits without a retained local branch/tag; removing its recovery log may make them unrecoverable.")
        }
        value.localCommits = try git.text(path, ["log", "--format=%H %s", "--max-count=31", "HEAD", "--not", "--remotes"]).components(separatedBy: "\n").filter { !$0.isEmpty }
        let upstream = try git.text(path, ["rev-parse", "--symbolic-full-name", "@{upstream}"], allowed: [0, 128])
        if upstream.hasPrefix("refs/") {
            value.upstream = upstream
            let counts = try git.text(path, ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"]).split(whereSeparator: \.isWhitespace)
            if counts.count == 2 { value.ahead = Int(counts[0]); value.behind = Int(counts[1]) }
        }
        if let ref = configuration.integrationRefs[value.worktree.commonDirectory] {
            guard ref.hasPrefix("refs/"), !ref.contains("\n"), !ref.contains("\0") else { throw FeatureFailure(message: "Choose a full named integration reference, such as refs/heads/main.") }
            value.integrationRef = ref
            value.integrationOID = try git.text(path, ["rev-parse", "--verify", ref + "^{commit}"])
            value.merged = try git.run(path, ["merge-base", "--is-ancestor", "HEAD", value.integrationOID!], allowed: [0, 1]).code == 0
        }
        return unretained.isEmpty && !recoveryUnretained
    }

    private func fileManifest(path: String, ignored: Set<String>) throws -> (digest: String, bytes: Int64, ignoredFiles: [WorktreeIgnoredFile], nested: [String]) {
        var entries: [String] = [], bytes: Int64 = 0, failed = false
        var ignoredFiles: [WorktreeIgnoredFile] = [], nested: [String] = []
        let root = URL(fileURLWithPath: path)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey],
            options: [], errorHandler: { _, _ in failed = true; return false }) else { throw FeatureFailure(message: "Cannot inspect checkout files.") }
        for case let url as URL in walker {
            guard entries.count < 150_000, !Task.isCancelled else { throw FeatureFailure(message: "Checkout file inspection limit exceeded.") }
            let relative = String(url.path.dropFirst(path.count + 1))
            if relative == ".git" {
                // skipDescendants on a FILE can skip the next directory's contents on macOS.
                // Linked worktrees use a .git file, whereas a primary checkout uses a directory.
                if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { walker.skipDescendants() }
                continue
            }
            if url.lastPathComponent == ".git" { nested.append(String(url.deletingLastPathComponent().path.dropFirst(path.count + 1))) }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw FeatureFailure(message: "File changed during inspection.") }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                if url.lastPathComponent != ".git", FileManager.default.fileExists(atPath: url.appending(path: "HEAD").path) && FileManager.default.fileExists(atPath: url.appending(path: "objects").path) { nested.append(relative) }
            } else if (info.st_mode & S_IFMT) != S_IFREG && (info.st_mode & S_IFMT) != S_IFLNK { throw FeatureFailure(message: "Special file cannot be safely reviewed.") }
            if ignored.contains(relative) {
                ignoredFiles.append(WorktreeIgnoredFile(path: relative, estimatedBytes: Int64(info.st_blocks) * 512,
                    symbolicLink: (info.st_mode & S_IFMT) == S_IFLNK))
            }
            bytes += Int64(info.st_blocks) * 512
            entries.append("\(relative)\0\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec):\(info.st_ctimespec)")
        }
        guard !failed else { throw FeatureFailure(message: "Some checkout files were inaccessible.") }
        guard ignoredFiles.count == ignored.count else { throw FeatureFailure(message: "Ignored files changed or could not be completely inspected. Refresh before review.") }
        return (GitWorktree.digest(entries.sorted().joined(separator: "\n")), bytes, ignoredFiles.sorted { $0.path < $1.path }, Set(nested).sorted())
    }
}
