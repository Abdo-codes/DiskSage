import Foundation

enum WorktreeGitConfiguration {
    static func validate(_ git: WorktreeGitProcess, path: String) throws {
        let pattern = "^(filter\\.|core\\.(sparsecheckout|sparsecheckoutcone|ignorestat|checkstat|worktree)|extensions\\.(partialclone|worktreeconfig)|remote\\..*\\.promisor)"
        let keys = try git.run(path, ["config", "--null", "--name-only", "--get-regexp", pattern], allowed: [0, 1]).data
        for key in names(keys) {
            if key == "extensions.worktreeconfig" || key == "core.worktree" { continue }
            if key == "core.checkstat", try git.text(path, ["config", "--get", key]).lowercased() == "default" { continue }
            if key.hasPrefix("core.sparsecheckout") || key == "core.ignorestat" || key.hasSuffix(".promisor") {
                if try git.text(path, ["config", "--type=bool", "--get", key]) == "false" { continue }
            }
            throw FeatureFailure(message: "Unsupported Git setting: \(key). No configured helper was executed.")
        }
    }

    static func validateLocalFile(_ git: WorktreeGitProcess, path: String, admin: String) throws {
        let file = URL(fileURLWithPath: admin + "/config.worktree")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw FeatureFailure(message: "Symlinked worktree configuration requires external preservation.")
        }
        let keys = names(try git.run(path, ["config", "--file", file.path, "--no-includes", "--null", "--name-only", "--list"]).data)
        let derived = Set(["core.bare", "core.worktree", "core.untrackedcache", "core.sparsecheckout", "core.sparsecheckoutcone", "core.ignorestat", "core.checkstat"])
        let custom = Set(keys).subtracting(derived).sorted()
        guard custom.isEmpty else {
            throw FeatureFailure(message: "Worktree-local settings need preservation: \(custom.prefix(6).joined(separator: ", ")).")
        }
        // Effective sparse/hidden-state settings are checked by validate(). The
        // effective checkout root is independently matched to Git's registration.
    }

    private static func names(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self).lowercased() }
    }
}
