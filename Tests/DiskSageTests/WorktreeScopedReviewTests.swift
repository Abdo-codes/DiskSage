import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@Suite(.serialized)
struct WorktreeScopedReviewTests {
    @Test func scopedInventoryRetainsApprovedPolicyAndNeverGrantsAccess() throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        let service = WorktreeService(inspector: WorktreeInspector(checkActivity: false))
        let result = try service.inventory(fixture.configuration, repositoryRoot: fixture.main.path)
        let linked = try #require(result.items.first { $0.worktree.path == fixture.checkout.path })
        #expect(result.scopedCommonDirectory == linked.worktree.commonDirectory)
        #expect(linked.canRemove, "\(linked.blockers)")
        #expect(throws: FeatureFailure.self) {
            try service.inventory(WorktreeConfiguration(roots: [fixture.checkout.path]), repositoryRoot: fixture.main.path)
        }
        #expect(throws: FeatureFailure.self) { try service.inventory(fixture.configuration, repositoryRoot: fixture.root.path) }
        let alias = fixture.root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.main)
        #expect(throws: FeatureFailure.self) { try service.inventory(fixture.configuration, repositoryRoot: alias.path) }
    }

    @MainActor @Test func manyNestedWarningsFitPreviewAndEveryWarningRemainsPageable() throws {
        var item = WorktreesFeatureTests.item()
        item.removalWarnings = (0..<52).map { "Nested Git repository data will be deleted, including its branches and unsaved work: .build-dd/SourcePackages/checkouts/\(String(repeating: "dependency-", count: 12))\($0)." }
        let items = (0..<8).map { index -> WorktreeInspection in var copy = item; copy.worktree.path += "-\(index)"; return copy }
        let preview = try WorktreeToolPresentation.preview(WorktreePreview(items: items))
        #expect(preview.object?["checkouts"]?.array?.count == 8)
        #expect(try JSONEncoder().encode(AgentToolReply(data: preview)).count < 24_000)
        let summary = try WorktreeToolPresentation.summary(item)
        #expect(summary.object?["removal_warning_count"] == .integer(52))
        #expect(summary.object?["removal_warnings_truncated"] == .bool(true))
        #expect(summary.object?["removal_warnings"]?.array?.count == 3)
        var offset = 0, warnings: [String] = []
        repeat {
            let data = try WorktreeToolPresentation.detail(item, args: ["offset": .integer(offset), "limit": .integer(10)])
            let page = try #require(data.object?["details"]?.object)
            warnings += (page["entries"]?.array ?? []).filter { $0.object?["kind"] == .string("removal_warning") }.compactMap { $0.object?["value"]?.string }
            guard let next = page["next_offset"]?.integer else { break }; offset = next
        } while true
        #expect(warnings == item.discardReasons)
        #expect(items.allSatisfy { $0.discardReasons.count == 52 })
    }
}

@MainActor
struct WorktreeScopedFeatureTests {
    @Test func refreshUpdatesInPlaceAndKeepsUnseenRowsOutOfRemoval() async {
        let first = WorktreesFeatureTests.item()
        var unseen = first
        unseen.worktree.path += "-unseen"
        var updated = first
        updated.estimatedBytes = 4200
        var discovered = first
        discovered.worktree.path += "-new"
        let result = WorktreeInventory(items: [discovered, updated])
        var state = AppFeature.State()
        state.worktrees.items = [first, unseen]
        state.worktrees.selection = [first.id, unseen.id]
        state.worktrees.loaded = true
        let store = ManagementTestSupport.store(state) {
            $0.worktrees.inventory = { _, _ in result }
        }

        await store.send(.worktrees(.load)).finish()
        #expect(store.worktrees.items.map(\.id) == [first.id, unseen.id, discovered.id])
        #expect(store.worktrees.items.first?.estimatedBytes == 4200)
        #expect(store.worktrees.items.first { $0.id == unseen.id }?.canRequestRemoval == false)
        #expect(store.worktrees.selection == [first.id])
        await store.send(.worktrees(.load)).finish()
        #expect(store.worktrees.items.map(\.id) == [first.id, unseen.id, discovered.id])
    }

    @Test func scopedRefreshPreservesOtherRepositoriesWithoutExpandingRemovalScope() async {
        let first = WorktreesFeatureTests.item()
        var other = first
        other.worktree.path = "/other/feature"
        other.worktree.commonDirectory = "/other/main/.git"
        let result = WorktreeInventory(scopedCommonDirectory: first.worktree.commonDirectory)
        var state = AppFeature.State()
        state.worktrees.items = [first, other]
        state.worktrees.selection = [other.id]
        state.worktrees.loaded = true
        let store = ManagementTestSupport.store(state) {
            $0.worktrees.inventory = { _, _ in result }
        }

        await store.send(.worktrees(.loadRepository("/fixture/main"))).finish()
        #expect(store.worktrees.items.last == other)
        #expect(store.worktrees.reviewItems.map(\.id) == [first.id])
        #expect(store.worktrees.reviewItems.first?.canRequestRemoval == false)
        #expect(store.worktrees.selection == [other.id])
        await store.send(.worktrees(.preview)).finish()
        #expect(store.worktrees.pending == nil)
    }

    @Test func toolRefreshAndPostRemovalReloadUseTheRequestedApprovedRepository() async throws {
        let root = "/fixture/repository", calls = LockIsolated<[String?]>([])
        let configuration = WorktreeConfiguration(roots: ["/fixture"])
        let saved = LockIsolated(0)
        let store = ManagementTestSupport.store {
            $0.worktrees.configuration = { configuration }
            $0.worktrees.saveConfiguration = { _ in saved.withValue { $0 += 1 } }
            $0.worktrees.inventory = { _, scope in calls.withValue { $0.append(scope) }; return WorktreeInventory() }
        }
        await store.send(.agentToolRequest(try ManagementTestSupport.request("refresh_worktrees", ["repository_root": root]))).finish()
        #expect(calls.value == [root] && store.worktrees.repositoryRoot == root)
        #expect(store.worktrees.configuration == configuration && saved.value == 0)
        await store.send(.worktrees(.removed([]))).finish()
        #expect(calls.value == [root, root])
        await store.send(.worktrees(.load)).finish()
        #expect(calls.value == [root, root, nil] && store.worktrees.repositoryRoot == nil)
    }
}
