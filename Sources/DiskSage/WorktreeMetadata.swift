import CryptoKit
import Darwin
import Foundation

/// Pins the private data that Git removes with a linked checkout. Contents stay out of UI/MCP.
enum WorktreeMetadata {
    static func inspect(admin: String, common: String) throws -> (warnings: [String], digest: String, disposable: Bool, tips: [String]) {
        let manager = FileManager.default
        let blocked = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "rebase-merge", "rebase-apply", "sequencer", "AUTO_MERGE"]
        for name in blocked where manager.fileExists(atPath: admin + "/" + name) {
            throw FeatureFailure(message: "Worktree has an in-progress Git operation: \(name). Finish or abort it first.")
        }
        var warnings: [String] = [], entries: [String] = []
        var disposable = true, tips: [String] = []
        if admin != common {
            let allowed = Set(["HEAD", "ORIG_HEAD", "REBASE_HEAD", "FETCH_HEAD", "COMMIT_EDITMSG", "index", "logs", "refs", "config.worktree", "commondir", "gitdir", "locked"])
            for name in try manager.contentsOfDirectory(atPath: admin).sorted() where !allowed.contains(name) {
                warnings.append("Private Git metadata will be deleted: \(name).")
                let url = URL(fileURLWithPath: admin + "/" + name)
                let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                let marker = name == "CLAUDE_BASE" && attributes?.isRegularFile == true && attributes?.isSymbolicLink != true && (attributes?.fileSize ?? 129) <= 128
                    ? try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) : nil
                if name == "CLAUDE_BASE", let marker, [40, 64].contains(marker.utf8.count),
                   marker.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                    tips.append(marker)
                } else { disposable = false }
            }
            var failed = false, bytes = 0
            guard let walker = manager.enumerator(at: URL(fileURLWithPath: admin), includingPropertiesForKeys: nil,
                errorHandler: { _, _ in failed = true; return false }) else {
                throw FeatureFailure(message: "Cannot inspect private Git metadata.")
            }
            for case let url as URL in walker {
                guard entries.count < 50_000, !Task.isCancelled else { throw FeatureFailure(message: "Private Git metadata inspection limit exceeded.") }
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw FeatureFailure(message: "Private Git metadata changed during inspection.") }
                let relative = String(url.path.dropFirst(admin.count + 1))
                if url.pathExtension == "lock" { throw FeatureFailure(message: "Git lock file present: \(relative).") }
                guard (info.st_mode & S_IFMT) == S_IFREG || (info.st_mode & S_IFMT) == S_IFDIR else {
                    throw FeatureFailure(message: "Symlinked or special private Git metadata is unsupported: \(relative).")
                }
                var hash = "directory"
                if (info.st_mode & S_IFMT) == S_IFREG {
                    guard info.st_size >= 0, info.st_size < 16_000_000, bytes + Int(info.st_size) < 32_000_000 else {
                        throw FeatureFailure(message: "Private Git metadata exceeds the review size limit.")
                    }
                    bytes += Int(info.st_size)
                    hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                    if relative.hasPrefix("refs/") { disposable = false; warnings.append("Private Git reference will be deleted: \(relative).") }
                    if relative.hasPrefix("logs/"), relative != "logs/HEAD" { disposable = false; warnings.append("Private Git recovery log will be deleted: \(relative).") }
                }
                entries.append("\(relative)\0\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec):\(info.st_ctimespec)\0\(hash)")
            }
            guard !failed else { throw FeatureFailure(message: "Some private Git metadata could not be inspected.") }
        }
        for root in Set([admin, common]) {
            guard let walker = manager.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil) else { throw FeatureFailure(message: "Cannot inspect Git locks.") }
            var count = 0
            for case let url as URL in walker {
                count += 1
                guard count < 50_000 else { throw FeatureFailure(message: "Git metadata inspection limit exceeded.") }
                if ["objects", "logs"].contains(url.lastPathComponent),
                   try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { walker.skipDescendants() }
                if url.pathExtension == "lock" { throw FeatureFailure(message: "Git lock file present: \(url.lastPathComponent).") }
            }
        }
        return (warnings.sorted(), GitWorktree.digest(entries.sorted().joined(separator: "\n")), disposable, tips)
    }
}
