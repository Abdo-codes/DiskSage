import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@Suite(.serialized)
struct WorktreeIgnoredReviewTests {
    @Test(arguments: [false, true])
    func ignoredSecretsAndGeneratedFilesNeedExplicitNativeApproval(approved: Bool) throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        try Data("Disposable local settings".utf8).write(to: fixture.checkout.appending(path: ".env"))
        let build = fixture.checkout.appending(path: ".build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data(repeating: 65, count: 8192).write(to: build.appending(path: "file\t日本\n.bin"))
        let outside = fixture.root.appending(path: "keep-outside")
        try Data("Keep this target".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: build.appending(path: "link"), withDestinationURL: outside)
        let item = try fixture.inspect()
        #expect(item.canRemove && item.hasIgnoredFiles && item.ignoredFileCount == 3, "\(item.blockers)")
        #expect(item.ignoredFiles?.contains { $0.path == ".env" && $0.estimatedBytes > 0 } == true)
        #expect(item.ignoredFiles?.contains { $0.path == ".build/link" && $0.symbolicLink } == true)
        let result = try fixture.remove(WorktreePreview(items: [item], ignoredFilesApproved: approved))
        #expect(result.count == 1 && result[0].succeeded == approved, "\(result)")
        #expect(FileManager.default.fileExists(atPath: fixture.checkout.path) == !approved)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(try fixture.git.text(fixture.main.path, ["rev-parse", "refs/heads/feature"]) == item.worktree.head)
    }

    @Test(arguments: ["added", "changed", "untracked"])
    func changingFilesAfterIgnoredReviewInvalidatesApproval(kind: String) throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        try "original".write(to: fixture.checkout.appending(path: ".env"), atomically: true, encoding: .utf8)
        let item = try fixture.inspect()
        #expect(item.canRemove)
        switch kind {
        case "added":
            let build = fixture.checkout.appending(path: ".build")
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            try "new ignored file".write(to: build.appending(path: "new"), atomically: true, encoding: .utf8)
        case "changed": try "changed settings".write(to: fixture.checkout.appending(path: ".env"), atomically: true, encoding: .utf8)
        default: try "Keep new work".write(to: fixture.checkout.appending(path: "untracked.txt"), atomically: true, encoding: .utf8)
        }
        let result = try fixture.remove(WorktreePreview(items: [item], ignoredFilesApproved: true))
        #expect(result.count == 1 && !result[0].succeeded && result[0].message.contains("Evidence changed"))
        #expect(FileManager.default.fileExists(atPath: fixture.checkout.path))
    }

    @Test func oldPreviewJournalsRemainReadableWithoutIgnoredApprovalFields() throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        let preview = WorktreePreview(items: [try fixture.inspect()])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preview)) as? [String: Any])
        object["ignoredFilesApproved"] = nil; object["quickReviewTotal"] = nil; object["discardChangesApproved"] = nil
        var rows = try #require(object["items"] as? [[String: Any]])
        rows[0]["ignoredFiles"] = nil; rows[0]["removalWarnings"] = nil; object["items"] = rows
        let decoded = try JSONDecoder().decode(WorktreePreview.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.ignoredFilesApproved == nil && decoded.items[0].ignoredFiles == nil)
        #expect(decoded.discardChangesApproved == nil && !decoded.items[0].requiresDiscardApproval)
    }
    @Test func oversizedApprovalCannotCorruptSavedScope() throws {
        let root = URL(fileURLWithPath: "/private/tmp/disksage-journal-limit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorktreeRepository(url: root.appending(path: "worktrees.json"))
        let original = WorktreeConfiguration(roots: ["/fixture"])
        try repository.save(original)
        var item = WorktreeInspection(worktree: GitWorktree(path: "/fixture/worktree", commonDirectory: "/fixture/main/.git",
            branch: "refs/heads/feature", head: "123", locked: false, missing: false, main: false))
        item.ignored = [String(repeating: "x", count: 32_000_001)]
        #expect(throws: FeatureFailure.self) { try repository.intent(WorktreePreview(items: [item])) }
        #expect(try repository.configuration() == original)
    }

}

@MainActor
struct WorktreeQuickCleanupTests {
    @Test func shortcutPreparesReviewAndNeverDeletesWithoutIgnoredApproval() async throws {
        var item = WorktreesFeatureTests.item(); item.cleanupConcerns = []
        item.ignored = [".build/output"]; item.ignoredFiles = [.init(path: ".build/output", estimatedBytes: 4096, symbolicLink: false)]
        var blocked = item; blocked.worktree.path = "/fixture/dirty"; blocked.blockers = ["Uncommitted changes"]
        var initial = AppFeature.State(); initial.worktrees.loaded = true; initial.worktrees.items = [item, blocked]
        let calls = LockIsolated<[WorktreePreview]>([])
        let store = ManagementTestSupport.store(initial) {
            $0.worktrees.remove = { preview in calls.withValue { $0.append(preview) }; return [] }
        }
        await store.send(.worktrees(.reviewUnused)).finish()
        let pending = try #require(store.worktrees.pending)
        #expect(pending.items.map(\.id) == [item.id] && pending.items[0].ignoredFileCount == item.ignoredFileCount && pending.quickReviewTotal == 1 && store.isBusy)
        #expect(calls.value.isEmpty)
        await store.send(.worktrees(.confirm(pending.id))).finish()
        #expect(calls.value.isEmpty && store.worktrees.pending != nil)
        await store.send(.worktrees(.confirm(pending.id, ignoredFilesApproved: true))).finish()
        #expect(calls.value.count == 1 && calls.value[0].ignoredFilesApproved == true)
    }

    @Test func shortcutLoadsEvidenceAndPreparesAllDisposableWorktrees() async throws {
        let items = (0..<25).map { index -> WorktreeInspection in
            var item = WorktreesFeatureTests.item(); item.cleanupConcerns = []; item.worktree.path = "/fixture/\(index)"; return item
        }
        let calls = LockIsolated(0)
        let store = ManagementTestSupport.store {
            $0.worktrees.inventory = { _, _ in WorktreeInventory(items: items) }
            $0.worktrees.remove = { _ in calls.withValue { $0 += 1 }; return [] }
        }
        await store.send(.worktrees(.reviewUnused)).finish()
        #expect(store.worktrees.pending?.items.count == 25 && store.worktrees.pending?.quickReviewTotal == 25)
        #expect(calls.value == 0)
    }

    @Test func agentsCanPreviewUnusedButCannotApproveIgnoredDeletion() async throws {
        var item = WorktreesFeatureTests.item(); item.cleanupConcerns = []; item.ignored = [".build/output"]
        var initial = AppFeature.State(); initial.worktrees.loaded = true; initial.worktrees.items = [item]
        let calls = LockIsolated(0)
        let store = ManagementTestSupport.store(initial) {
            $0.diskSage.preferences = { CleanupPreferences(agentPolicy: .automaticLowRisk) }
            $0.worktrees.remove = { _ in calls.withValue { $0 += 1 }; return [] }
        }
        await store.send(.agentToolRequest(try ManagementTestSupport.request("preview_unused_worktrees"))).finish()
        let value = try #require(store.agentToolReply?.data?.object)
        #expect(value["ignored_files_require_native_approval"] == .bool(true))
        let token = try #require(value["snapshot_token"]?.string)
        await store.send(.agentToolRequest(try ManagementTestSupport.request("remove_worktrees", ["snapshot_token": token]))).finish()
        #expect(store.worktrees.pending?.requiresIgnoredApproval == true && calls.value == 0)
        #expect(throws: MCPServer.MCPError.self) {
            try MCPManagementSchema.command(name: "remove_worktrees", arguments: ["request_id": UUID().uuidString,
                "snapshot_token": token, "ignoredFilesApproved": true])
        }
        await store.send(.worktrees(.dismiss)).finish()
        #expect(calls.value == 0)
    }

    @Test func quickReviewDoesNotRunWhileAnotherCleanupIsBusy() async {
        var initial = AppFeature.State(); initial.operation = .cleaning; initial.worktrees.loaded = true
        initial.worktrees.items = [WorktreesFeatureTests.item()]
        let store = ManagementTestSupport.store(initial)
        await store.send(.worktrees(.reviewUnused)).finish()
        #expect(store.worktrees.pending == nil && !store.worktrees.quickReviewRequested)
    }
    @Test func leavingReviewCancelsTheQueuedShortcutWithoutStoppingInspection() async {
        let id = UUID()
        var initial = AppFeature.State(); initial.worktrees.loading = true; initial.worktrees.loadID = id
        initial.worktrees.quickReviewRequested = true
        let store = ManagementTestSupport.store(initial)
        await store.send(.worktrees(.dismiss)).finish()
        await store.send(.worktrees(.loaded(id, .success(WorktreeInventory(items: [WorktreesFeatureTests.item()]))))).finish()
        #expect(store.worktrees.pending == nil && !store.worktrees.quickReviewRequested && store.worktrees.loaded)
    }

}
