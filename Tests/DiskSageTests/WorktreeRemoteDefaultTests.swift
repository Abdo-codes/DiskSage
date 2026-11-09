import Foundation
import Testing
@testable import DiskSage

/// A detached HEAD whose commit is on a remote's default branch is kept: that branch is never pruned.
/// A commit only on another remote branch is not kept, because those branches are pruned after a merge.
@Suite(.serialized)
struct WorktreeRemoteDefaultTests {
    @Test(arguments: [true, false])
    func detachedCommitOnTheRemoteDefaultBranchIsKept(onDefault: Bool) throws {
        let f = try WorktreeFixture(); defer { f.dispose() }
        let path = f.checkout.path
        _ = try f.git.run(path, ["switch", "--detach"])
        _ = try f.git.run(path, ["commit", "--allow-empty", "-m", "merged work"])
        let head = try f.git.text(path, ["rev-parse", "HEAD"])
        let base = try f.git.text(f.main.path, ["rev-parse", "main"])
        // Remote names can contain a slash. The remote must be configured for its HEAD to count.
        _ = try f.git.run(f.main.path, ["remote", "add", "team/origin", "https://example.invalid/repo.git"])
        _ = try f.git.run(f.main.path, ["update-ref", "refs/remotes/team/origin/main", onDefault ? head : base])
        _ = try f.git.run(f.main.path, ["symbolic-ref", "refs/remotes/team/origin/HEAD", "refs/remotes/team/origin/main"])
        _ = try f.git.run(f.main.path, ["remote", "add", "origin", "https://example.invalid/repo.git"])
        _ = try f.git.run(f.main.path, ["update-ref", "refs/remotes/origin/main", base])
        _ = try f.git.run(f.main.path, ["update-ref", "refs/remotes/origin/topic", head])
        // A symbolic alias that is not `<remote>/HEAD` does not make its target kept.
        _ = try f.git.run(f.main.path, ["symbolic-ref", "refs/remotes/origin/alias", "refs/remotes/origin/topic"])
        _ = try f.git.run(f.main.path, ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        // A dangling default of another remote is ignored.
        _ = try f.git.run(f.main.path, ["symbolic-ref", "refs/remotes/gone/HEAD", "refs/remotes/gone/main"])

        let item = try f.inspect()
        let warnings = item.removalWarnings ?? []
        let flagged = warnings.contains { $0.hasPrefix("Detached HEAD commits") || $0.hasPrefix("Worktree recovery history") }
        #expect(flagged == !onDefault, "\(warnings)")
        #expect(item.retainedRefs["refs/remotes/team/origin/main"] == (onDefault ? head : base))
        #expect(item.retainedRefs["refs/remotes/origin/main"] == base)
        #expect(item.retainedRefs["refs/remotes/origin/topic"] == nil)
    }

    @Test func removalSucceedsWithARetainedRemoteDefault() throws {
        let f = try WorktreeFixture(); defer { f.dispose() }
        let base = try f.git.text(f.main.path, ["rev-parse", "main"])
        _ = try f.git.run(f.main.path, ["remote", "add", "origin", "https://example.invalid/repo.git"])
        _ = try f.git.run(f.main.path, ["update-ref", "refs/remotes/origin/main", base])
        _ = try f.git.run(f.main.path, ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        let item = try f.inspect()
        #expect(item.retainedRefs["refs/remotes/origin/main"] == base)
        let results = try f.remove(WorktreePreview(items: [item]))
        #expect(results.count == 1 && results[0].succeeded, "\(results)")
        #expect(!FileManager.default.fileExists(atPath: f.checkout.path))
    }
}
