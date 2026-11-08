import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
struct WorktreeResponsivenessTests {
    @Test func confirmationClosesWhileRemovalContinuesAndBrowsingStaysAvailable() async throws {
        let first = WorktreesFeatureTests.item()
        var second = first; second.worktree.path += "-second"
        let jobID = UUID()
        let preview = WorktreePreview(items: [first], toolRequestID: jobID)
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let (release, finish) = AsyncStream<Void>.makeStream()
        let cancelled = LockIsolated<[UUID]>([])
        var state = AppFeature.State()
        state.worktrees.items = [first, second]; state.worktrees.loaded = true
        state.worktrees.pending = preview
        state.agentToolJobs[jobID] = .init(id: jobID, action: .manage, startedAt: Date(), phase: .awaitingConfirmation)
        let store = ManagementTestSupport.store(state) {
            $0.worktrees.remove = { _ in
                didStart.yield(())
                for await _ in release { break }
                return [.init(id: first.id, path: first.worktree.path, succeeded: true, message: "Removed")]
            }
            $0.worktrees.cancel = { id in cancelled.withValue { $0.append(id) } }
            $0.worktrees.inventory = { _, _ in .init(items: [second]) }
        }
        let removal = store.send(.worktrees(.confirm(preview.id)))
        for await _ in started { break }
        #expect(store.worktrees.pending == nil, "A running deletion must not keep the window modal.")
        #expect(store.worktrees.removing && store.isCleaning)
        #expect(store.agentToolJobs[jobID]?.phase == .cleaning)
        await store.send(.agentToolRequest(try ManagementTestSupport.request("get_dashboard"))).finish()
        let dashboard = try #require(store.agentToolReply?.data?.object)
        #expect(dashboard["confirmation"] == nil)
        #expect(dashboard["operation_id"] == .string(preview.id.uuidString))
        await store.send(.worktrees(.select([second.id]))).finish()
        #expect(store.worktrees.selection == [second.id])
        await store.send(.worktrees(.dismiss)).finish()
        #expect(store.worktrees.removing)
        #expect(store.agentToolJobs[jobID]?.phase == .cleaning)
        await store.send(.agentToolRequest(try ManagementTestSupport.request("cancel_operation", ["operation_id": preview.id.uuidString]))).finish()
        #expect(cancelled.value == [preview.id])
        finish.yield(()); finish.finish(); didStart.finish()
        await removal.finish()
        #expect(!store.worktrees.removing && !store.worktrees.loading)
        #expect(store.worktrees.selection == [second.id])
        #expect(store.worktrees.results.first?.succeeded == true)
    }

    @Test(arguments: [AppOperation.scanning, .automaticCleanup, .advising])
    func backgroundOperationsDoNotBlockWorktreeSelection(operation: AppOperation) async {
        let item = WorktreesFeatureTests.item()
        var state = AppFeature.State(); state.operation = operation
        state.worktrees.items = [item]; state.worktrees.loaded = true
        let store = ManagementTestSupport.store(state)
        await store.send(.worktrees(.select([item.id]))).finish()
        #expect(store.worktrees.selection == [item.id])
        #expect(store.operation == operation)
    }

    @Test func refreshKeepsExistingRowsAndSelectionBrowsable() async {
        let item = WorktreesFeatureTests.item(), id = UUID()
        var state = AppFeature.State()
        state.worktrees.items = [item]; state.worktrees.loaded = true
        state.worktrees.loading = true; state.worktrees.loadID = id
        let store = ManagementTestSupport.store(state)
        await store.send(.worktrees(.select([item.id]))).finish()
        #expect(store.worktrees.selection == [item.id])
        await store.send(.worktrees(.cancelLoad)).finish()
        #expect(store.worktrees.items == [item] && store.worktrees.selection == [item.id])
    }

    @Test func pollingBackgroundProgressUsesTheCapacitySnapshotWithoutSynchronousDiskAccess() async throws {
        let reads = LockIsolated(0)
        var state = AppFeature.State(); state.operation = .automaticCleanup; state.freeSpaceBytes = 12345
        let store = ManagementTestSupport.store(state) {
            $0.diskSage.freeSpace = { reads.withValue { $0 += 1 }; return 99 }
        }
        await store.send(.agentToolRequest(.init(action: .status))).finish()
        #expect(store.agentToolReply?.status?.freeSpaceBytes == 12345)
        await store.send(.agentToolRequest(try ManagementTestSupport.request("get_dashboard"))).finish()
        #expect(store.agentToolReply?.data?.object?["free_space_bytes"] == .integer(12345))
        #expect(reads.value == 0)
    }

    @Test func refreshLoadsItsDiskJournalAwayFromTheUIThread() async {
        let onMain = LockIsolated<Bool?>(nil)
        let configuration = WorktreeConfiguration(roots: ["/fixture"])
        let store = ManagementTestSupport.store {
            $0.worktrees.configuration = {
                onMain.setValue(Thread.isMainThread)
                return configuration
            }
        }
        await store.send(.worktrees(.load)).finish()
        #expect(onMain.value == false)
        #expect(store.worktrees.configuration == configuration && store.worktrees.loaded)
    }
}
