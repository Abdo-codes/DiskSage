import Foundation

enum WorktreeNestedPolicy {
    /// A disposable nested clone must not own or reference another checkout's shared Git data.
    static func validate(_ roots: [String], checkout: String, configuration: WorktreeConfiguration, git: WorktreeGitProcess, assessDisposable: Bool = false) throws -> [String] {
        var concerns: [String] = []
        guard roots.count <= 100 else { throw FeatureFailure(message: "Too many nested repositories for complete removal review.") }
        for relative in roots {
            let path = checkout + "/" + relative
            let common = try git.text(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
            _ = try WorktreePathGuard.identity(common)
            guard WorktreePathGuard.contains(checkout, common) else {
                throw FeatureFailure(message: "Nested checkout uses shared Git data outside this folder: \(relative). Remove it through its own worktree review first.")
            }
            let rows = try WorktreeParsing.records(git.run(path, ["worktree", "list", "--porcelain", "-z"]).data, common: common)
            guard rows.count == 1, let row = rows.first, WorktreePathGuard.contains(checkout, row.path),
                  !row.locked, !row.missing, !configuration.protectedIDs.contains(row.id) else {
                throw FeatureFailure(message: "Nested repository has additional, protected or locked checkouts: \(relative). Review those separately before removing the parent.")
            }
            if assessDisposable {
                do {
                    guard WorktreeValuePolicy.isGenerated(relative) else { throw FeatureFailure(message: "Nested repository outside generated caches: \(relative).") }
                    if row.head.isEmpty {
                        guard try git.text(path, ["config", "--get", "remote.origin.mirror"], allowed: [0, 1]) == "true" else {
                            throw FeatureFailure(message: "Nested repository is not a generated dependency mirror: \(relative).")
                        }
                    } else {
                        try git.rejectHelpers(path)
                        guard try git.text(path, ["status", "--porcelain=v2", "-z", "--untracked-files=normal", "--ignore-submodules=none"]).isEmpty else {
                            throw FeatureFailure(message: "Unsaved work inside cached dependency: \(relative).")
                        }
                        guard try git.text(path, ["rev-list", "--max-count=1", "HEAD", "--not", "--remotes"]).isEmpty else {
                            throw FeatureFailure(message: "Locally unique commits inside cached dependency: \(relative).")
                        }
                        guard try WorktreeIgnoredFiles.paths(git: git, checkout: path).allSatisfy(WorktreeValuePolicy.isGenerated) else {
                            throw FeatureFailure(message: "Local ignored files inside cached dependency: \(relative).")
                        }
                    }
                } catch { concerns.append(error.localizedDescription) }
            }
        }
        return concerns
    }
}
