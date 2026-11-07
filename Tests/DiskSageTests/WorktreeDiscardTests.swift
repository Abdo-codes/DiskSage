import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@Suite(.serialized)
struct WorktreeDiscardTests {
    @Test(arguments: [false, true])
    func onlyExactExplicitApprovalDiscardsChangesAndClaudeMetadata(approved: Bool) throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        let admin = try fixture.git.text(fixture.checkout.path, ["rev-parse", "--absolute-git-dir"])
        try "Claude base marker".write(toFile: admin + "/CLAUDE_BASE", atomically: true, encoding: .utf8)
        try "draft message".write(toFile: admin + "/COMMIT_EDITMSG", atomically: true, encoding: .utf8)
        try "edited source".write(to: fixture.checkout.appending(path: "file.txt"), atomically: true, encoding: .utf8)
        let build = fixture.checkout.appending(path: ".build-dd/nested")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        _ = try fixture.git.run(build.path, ["init", "-b", "nested"])
        let outside = fixture.root.appending(path: "keep-outside")
        try "keep me".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: build.appending(path: "link"), withDestinationURL: outside)
        let item = try fixture.inspect()
        #expect(item.canRequestRemoval && !item.canRemove && item.blockers.isEmpty, "\(item.blockers)")
        #expect(item.discardReasons.contains { $0.contains("CLAUDE_BASE") })
        #expect(item.discardReasons.contains { $0.contains("COMMIT_EDITMSG") })
        #expect(item.discardReasons.contains { $0.contains("Nested Git") })
        #expect(item.untracked == [".build-dd/"])
        #expect(WorktreeQuickCleanup.candidates([item]).isEmpty)
        let results = try fixture.remove(WorktreePreview(items: [item], discardChangesApproved: approved))
        #expect(results.count == 1 && results[0].succeeded == approved, "\(results)")
        #expect(FileManager.default.fileExists(atPath: fixture.checkout.path) == !approved)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(try fixture.git.text(fixture.main.path, ["rev-parse", "refs/heads/feature"]) == item.worktree.head)
        let log = try CleanupLogger(directory: fixture.root.appending(path: "logs")).events()
        if approved { #expect(log.contains { $0.message?.contains("discard approved: true") == true }) }
    }

    @Test(arguments: ["metadata", "nested", "source", "lock"])
    func changedDiscardEvidenceNeverUsesOldApproval(change: String) throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        let admin = try fixture.git.text(fixture.checkout.path, ["rev-parse", "--absolute-git-dir"])
        try "first".write(toFile: admin + "/CLAUDE_BASE", atomically: true, encoding: .utf8)
        let item = try fixture.inspect()
        #expect(item.canRequestRemoval && item.requiresDiscardApproval)
        switch change {
        case "metadata": try "other".write(toFile: admin + "/CLAUDE_BASE", atomically: true, encoding: .utf8)
        case "source": try "changed".write(to: fixture.checkout.appending(path: "file.txt"), atomically: true, encoding: .utf8)
        case "nested":
            let nested = fixture.checkout.appending(path: "new-repo")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            _ = try fixture.git.run(nested.path, ["init"])
        default: _ = try fixture.git.run(fixture.main.path, ["worktree", "lock", "--", fixture.checkout.path])
        }
        let results = try fixture.remove(WorktreePreview(items: [item], ignoredFilesApproved: true, discardChangesApproved: true))
        #expect(results.allSatisfy { !$0.succeeded }, "\(results)")
        #expect(FileManager.default.fileExists(atPath: fixture.checkout.path))
    }

    @Test(arguments: [false, true], [false, true])
    func ignoredAndDiscardConsentAreIndependent(ignored: Bool, discard: Bool) throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        try "unsaved edit".write(to: fixture.checkout.appending(path: "file.txt"), atomically: true, encoding: .utf8)
        try "local secret".write(to: fixture.checkout.appending(path: ".env"), atomically: true, encoding: .utf8)
        let item = try fixture.inspect()
        #expect(item.canRequestRemoval && item.hasIgnoredFiles && item.requiresDiscardApproval)
        let results = try fixture.remove(WorktreePreview(items: [item], ignoredFilesApproved: ignored, discardChangesApproved: discard))
        #expect(results.count == 1 && results[0].succeeded == (ignored && discard), "\(results)")
        #expect(FileManager.default.fileExists(atPath: fixture.checkout.path) == !(ignored && discard))
    }

    @Test(arguments: ["protected", "outside", "operation", "symlink", "locked", "main", "active"])
    func explicitDiscardCannotOverrideSafetyBlockers(kind: String) throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        var configuration = fixture.configuration
        var record = try fixture.item()
        let admin = try fixture.git.text(fixture.checkout.path, ["rev-parse", "--absolute-git-dir"])
        switch kind {
        case "protected": configuration.protectedIDs.insert(record.id)
        case "outside": configuration.roots = []
        case "operation": try "in progress".write(toFile: admin + "/MERGE_HEAD", atomically: true, encoding: .utf8)
        case "symlink": try FileManager.default.createSymbolicLink(atPath: admin + "/CLAUDE_BASE", withDestinationPath: fixture.main.path)
        case "locked": _ = try fixture.git.run(fixture.main.path, ["worktree", "lock", "--", fixture.checkout.path]); record = try fixture.item()
        case "main":
            record = try #require(WorktreeParsing.records(fixture.git.run(fixture.main.path, ["worktree", "list", "--porcelain", "-z"]).data,
                common: fixture.main.appending(path: ".git").path).first { $0.main })
        default: break
        }
        let inspector = WorktreeInspector(checkActivity: kind == "active", processPaths: kind == "active" ? [fixture.checkout.path] : [])
        let item = inspector.inspect(record, configuration: configuration)
        #expect(!item.canRequestRemoval && !item.blockers.isEmpty)
        let results = try fixture.remove(WorktreePreview(items: [item], ignoredFilesApproved: true, discardChangesApproved: true))
        #expect(results.allSatisfy { !$0.succeeded })
        #expect(FileManager.default.fileExists(atPath: record.path))
    }

    @Test(arguments: [false, true])
    func nestedSharedRepositoriesCannotBeDiscardedWithTheirParent(externalCommon: Bool) throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        let nested = fixture.checkout.appending(path: "nested"), outside = fixture.root.appending(path: "outside-linked")
        if externalCommon {
            _ = try fixture.git.run(fixture.main.path, ["worktree", "add", "--detach", "--", nested.path])
        } else {
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            _ = try fixture.git.run(nested.path, ["clone", "--no-hardlinks", "--", fixture.main.path, "."])
            _ = try fixture.git.run(nested.path, ["worktree", "add", "--detach", "--", outside.path])
        }
        let item = try fixture.inspect()
        #expect(!item.canRequestRemoval && item.blockers.contains { $0.contains("Nested") }, "\(item.blockers)")
        #expect(try fixture.remove(WorktreePreview(items: [item], ignoredFilesApproved: true, discardChangesApproved: true)).allSatisfy { !$0.succeeded })
        #expect(FileManager.default.fileExists(atPath: nested.path))
        #expect(FileManager.default.fileExists(atPath: fixture.main.path))
        if !externalCommon { #expect(FileManager.default.fileExists(atPath: outside.path)) }
    }

    @Test func untrackedDirectoryContentsRemainPinnedAfterTheGitPointer() throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        let nested = fixture.checkout.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appending(path: "unsaved.txt")
        try Data("original".utf8).write(to: file)
        let item = try fixture.inspect()
        #expect(item.canRequestRemoval && item.requiresDiscardApproval)
        // In-place editing leaves the parent directory's timestamps unchanged.
        try Data("modified".utf8).write(to: file)
        let results = try fixture.remove(WorktreePreview(items: [item], discardChangesApproved: true))
        #expect(results.allSatisfy { !$0.succeeded })
        #expect(try Data(contentsOf: file) == Data("modified".utf8))
    }

    @Test func genericCleanupStillFindsSourceRepositoriesAfterSymlinks() throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        let folder = fixture.root.appending(path: "generated"), nested = folder.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "link"), withDestinationURL: fixture.main)
        _ = try fixture.git.run(nested.path, ["init"])
        #expect(throws: FeatureFailure.self) { try ScheduledFolderPolicy.identity(of: folder) }
    }
}

@MainActor
struct WorktreeDiscardFeatureTests {
    @Test func agentPreviewOptInNeverApprovesDiscardAndConfirmationRequiresSeparateApproval() async throws {
        var item = WorktreesFeatureTests.item(); item.removalWarnings = ["Private metadata will be lost"]
        let calls = LockIsolated<[WorktreePreview]>([])
        var initial = AppFeature.State(); initial.worktrees.items = [item]; initial.worktrees.loaded = true
        let store = ManagementTestSupport.store(initial) {
            $0.diskSage.preferences = { CleanupPreferences(agentPolicy: .automaticLowRisk) }
            $0.worktrees.remove = { preview in calls.withValue { $0.append(preview) }; return [] }
        }
        await store.send(.agentToolRequest(try ManagementTestSupport.request("preview_worktree_removal", ["worktree_ids": [item.id]]))).finish()
        #expect(store.agentToolReply?.error != nil && store.worktrees.toolPreviews.isEmpty)
        await store.send(.agentToolRequest(try ManagementTestSupport.request("preview_worktree_removal", ["worktree_ids": [item.id], "allow_discard": true]))).finish()
        let token = try #require(store.agentToolReply?.data?.object?["snapshot_token"]?.string)
        #expect(store.agentToolReply?.data?.object?["discard_requires_native_approval"] == .bool(true))
        await store.send(.agentToolRequest(try ManagementTestSupport.request("remove_worktrees", ["snapshot_token": token]))).finish()
        let pending = try #require(store.worktrees.pending)
        #expect(calls.value.isEmpty && pending.discardChangesApproved != true)
        await store.send(.worktrees(.confirm(pending.id, ignoredFilesApproved: true))).finish()
        #expect(calls.value.isEmpty && !store.worktrees.removing)
        await store.send(.worktrees(.confirm(pending.id, discardChangesApproved: true))).finish()
        #expect(calls.value.count == 1 && calls.value[0].discardChangesApproved == true)
        #expect(throws: MCPServer.MCPError.self) {
            try MCPManagementSchema.command(name: "remove_worktrees", arguments: ["request_id": UUID().uuidString, "snapshot_token": token, "discard_changes_approved": true])
        }
    }

    @Test func manualRiskSelectionRemainsSeparateFromQuickCleanup() async throws {
        var item = WorktreesFeatureTests.item(); item.removalWarnings = ["Changes will be lost"]
        var blocked = item; blocked.worktree.path += "-blocked"; blocked.blockers = ["Locked"]
        var initial = AppFeature.State(); initial.worktrees.items = [item, blocked]; initial.worktrees.loaded = true
        let store = ManagementTestSupport.store(initial)
        await store.send(.worktrees(.select([item.id, blocked.id]))).finish()
        #expect(store.worktrees.selection == [item.id])
        await store.send(.worktrees(.preview)).finish()
        #expect(store.worktrees.pending?.requiresDiscardApproval == true)
        await store.send(.worktrees(.dismiss)).finish()
        await store.send(.worktrees(.reviewUnused)).finish()
        #expect(store.worktrees.pending == nil && store.worktrees.error != nil)
    }
}
