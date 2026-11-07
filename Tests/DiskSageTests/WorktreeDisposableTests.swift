import Foundation
import Testing
@testable import DiskSage

@Suite(.serialized)
struct WorktreeDisposableTests {
    @MainActor @Test func largeGeneratedInventoriesShareOneReviewWithoutLosingCounts() throws {
        var item = WorktreesFeatureTests.item()
        item.cleanupConcerns = []; item.ignored = [".build/"]
        item.ignoredFiles = (0..<5000).map { .init(path: ".build/\(String(repeating: "generated-", count: 12))\($0)", estimatedBytes: 4096, symbolicLink: false) }
        let items = (0..<50).map { index -> WorktreeInspection in var copy = item; copy.worktree.path += "-\(index)"; return copy }
        let preview = try WorktreeQuickCleanup.preview(items, id: UUID())
        #expect(preview.items.count == 50 && !preview.requiresExtraAcknowledgement)
        #expect(preview.items.allSatisfy { $0.ignoredFileCount == 5000 && $0.ignoredBytes == 20_480_000 && $0.fingerprint == item.fingerprint })
        #expect(try JSONEncoder().encode(preview).count < 16_000_000)
        let reply = try WorktreeToolPresentation.preview(preview)
        #expect(reply.object?["checkouts_total"] == .integer(50))
        #expect(reply.object?["checkouts_truncated"] == .bool(true))
        #expect(try JSONEncoder().encode(AgentToolReply(data: reply)).count < 24_000)
    }

    @Test func changesInsideCompactedGeneratedFoldersStillInvalidateApproval() throws {
        let f = try WorktreeFixture(); defer { f.dispose() }
        let folder = f.checkout.appending(path: ".build")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "artifact")
        try Data("before".utf8).write(to: file)
        var preview = try WorktreeQuickCleanup.preview([f.inspect()], id: UUID())
        preview.ignoredFilesApproved = true
        try Data("edited".utf8).write(to: file)
        #expect(try f.remove(preview).allSatisfy { !$0.succeeded })
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
    @Test func generatedOutputAndAnchoredClaudeMarkersNeedOnlyOneDeleteClick() throws {
        let f = try WorktreeFixture(); defer { f.dispose() }
        let admin = try f.git.text(f.checkout.path, ["rev-parse", "--absolute-git-dir"])
        let head = try f.git.text(f.checkout.path, ["rev-parse", "HEAD"])
        try head.write(toFile: admin + "/CLAUDE_BASE", atomically: true, encoding: .utf8)
        for name in [".build", ".build-dd"] {
            let folder = f.checkout.appending(path: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("generated".utf8).write(to: folder.appending(path: "artifact"))
        }
        let item = try f.inspect()
        #expect(item.isDisposable, "\(item.cleanupConcerns ?? item.blockers)")
        let preview = try WorktreeQuickCleanup.preview([item], id: UUID())
        #expect(!preview.requiresExtraAcknowledgement && preview.requiresIgnoredApproval && preview.requiresDiscardApproval)
        #expect(try f.remove(preview).allSatisfy { !$0.succeeded })
        var confirmed = preview
        confirmed.id = UUID(); confirmed.ignoredFilesApproved = true; confirmed.discardChangesApproved = true
        #expect(try f.remove(confirmed).allSatisfy(\.succeeded))
        #expect(try f.git.text(f.main.path, ["rev-parse", "refs/heads/feature"]) == head)
    }

    @Test(arguments: ["source", "notes", "secret", "recovery", "draft", "marker"])
    func meaningfulDataNeverEntersDisposableCleanup(kind: String) throws {
        let f = try WorktreeFixture(); defer { f.dispose() }
        let admin = try f.git.text(f.checkout.path, ["rev-parse", "--absolute-git-dir"])
        switch kind {
        case "source": try "unsaved".write(to: f.checkout.appending(path: "file.txt"), atomically: true, encoding: .utf8)
        case "notes": try "keep".write(to: f.checkout.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        case "secret": try "secret".write(to: f.checkout.appending(path: ".env"), atomically: true, encoding: .utf8)
        case "recovery":
            _ = try f.git.run(f.checkout.path, ["commit", "--allow-empty", "-m", "unretained"])
            _ = try f.git.run(f.checkout.path, ["reset", "--hard", "HEAD~1"])
        case "draft": try "unsaved draft".write(toFile: admin + "/COMMIT_EDITMSG", atomically: true, encoding: .utf8)
        default: try "not a generated marker".write(toFile: admin + "/CLAUDE_BASE", atomically: true, encoding: .utf8)
        }
        let item = try f.inspect()
        #expect(!item.isDisposable && item.cleanupConcerns?.isEmpty == false)
        #expect(WorktreeQuickCleanup.candidates([item]).isEmpty)
        #expect(WorktreePreview(items: [item]).requiresExtraAcknowledgement)
        #expect(FileManager.default.fileExists(atPath: f.checkout.path))
    }

    @Test(arguments: ["clean", "dirty", "local-commit", "mirror", "bare"])
    func nestedCachesMustBeReproducibleToUseTheSimpleFlow(kind: String) throws {
        let f = try WorktreeFixture(); defer { f.dispose() }
        let folder = f.checkout.appending(path: ".build-dd/SourcePackages")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let nested = folder.appending(path: "dependency")
        _ = try f.git.run(folder.path, ["clone"] + (kind == "mirror" ? ["--mirror"] : kind == "bare" ? ["--bare"] : []) + ["--no-hardlinks", "--", f.main.path, nested.path])
        if kind == "dirty" { try "edit".write(to: nested.appending(path: "file.txt"), atomically: true, encoding: .utf8) }
        if kind == "local-commit" {
            _ = try f.git.run(nested.path, ["config", "user.name", "Fixture"])
            _ = try f.git.run(nested.path, ["config", "user.email", "fixture@example.invalid"])
            _ = try f.git.run(nested.path, ["config", "commit.gpgsign", "false"])
            _ = try f.git.run(nested.path, ["commit", "--allow-empty", "-m", "local"])
        }
        let item = try f.inspect()
        #expect(item.canRequestRemoval, "\(item.blockers)")
        #expect(item.isDisposable == (kind == "clean" || kind == "mirror"), "\(item.cleanupConcerns ?? [])")
    }
}
