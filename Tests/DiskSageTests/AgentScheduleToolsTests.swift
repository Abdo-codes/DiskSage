import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

@MainActor
struct AgentScheduleToolsTests {
    @Test(arguments: [AgentCleanupPolicy.disabled, .confirm, .automaticLowRisk])
    func registrationHonorsPolicyAndRequiresAnExistingAuthorizedFolder(policy: AgentCleanupPolicy) async throws {
        let writes = LockIsolated<[ToolMutationReceipt]>([])
        let store = ManagementTestSupport.store(ManagementTestSupport.initial()) {
            $0.diskSage.preferences = { CleanupPreferences(agentPolicy: policy) }
            $0.management.save = { _, receipt in writes.withValue { $0.append(receipt) } }
        }
        let request = try ManagementTestSupport.request("create_schedule", ManagementTestSupport.createArguments)
        await store.send(.agentToolRequest(request)).finish()
        if policy == .disabled {
            #expect(store.schedules.isEmpty && writes.value.isEmpty)
            #expect(store.agentToolReply?.error != nil)
        } else {
            #expect(store.schedules.count == 1)
            #expect(store.schedules[0].id == request.requestID)
            #expect(store.schedules[0].isEnabled == (policy == .automaticLowRisk))
            #expect(store.schedules[0].revision == 1 && store.schedules[0].nextRun != nil)
            #expect(writes.value.count == 1)
            await store.send(.agentToolRequest(request)).finish()
            #expect(writes.value.count == 1)
            #expect(store.agentToolReply?.job?.phase == .succeeded)
        }
    }

    @Test(arguments: ["pause_schedule", "remove_schedule", "update_schedule"])
    func mutationsRequireCurrentRevisionAndRefuseChangedRetries(name: String) async throws {
        let store = ManagementTestSupport.store(ManagementTestSupport.initial()) {
            $0.diskSage.preferences = { CleanupPreferences(agentPolicy: .automaticLowRisk) }
        }
        let create = try ManagementTestSupport.request("create_schedule", ManagementTestSupport.createArguments)
        await store.send(.agentToolRequest(create)).finish()
        let schedule = try #require(store.schedules.first)
        var args: [String: Any] = ["schedule_id": schedule.id.uuidString, "expected_revision": 0]
        if name == "update_schedule" { args["hour"] = 4 }
        let stale = try ManagementTestSupport.request(name, args, id: 101)
        await store.send(.agentToolRequest(stale)).finish()
        #expect(store.agentToolReply?.error?.contains("stale revision") == true)
        #expect(store.schedules == [schedule])
        args["expected_revision"] = 1
        let valid = try ManagementTestSupport.request(name, args, id: 102)
        await store.send(.agentToolRequest(valid)).finish()
        #expect(store.agentToolReply?.job?.phase == .succeeded)
        if name == "remove_schedule" { #expect(store.schedules.isEmpty) }
        else {
            #expect(store.schedules[0].revision == 2)
            #expect(name == "pause_schedule" ? !store.schedules[0].isEnabled : store.schedules[0].hour == 4)
        }
        var changed = valid
        changed.arguments?["expected_revision"] = .integer(2)
        await store.send(.agentToolRequest(changed)).finish()
        #expect(store.agentToolReply?.error?.contains("different request") == true)
    }

    @Test(arguments: [false, true])
    func allContentsRequireHumanApprovalAndDecliningNeverRegisters(approve: Bool) async throws {
        let writes = LockIsolated(0)
        let store = ManagementTestSupport.store(ManagementTestSupport.initial()) {
            $0.diskSage.preferences = { CleanupPreferences(agentPolicy: .automaticLowRisk) }
            $0.management.save = { _, _ in writes.withValue { $0 += 1 } }
        }
        var args = ManagementTestSupport.createArguments; args["scope"] = "folderContents"
        let request = try ManagementTestSupport.request("create_schedule", args)
        await store.send(.agentToolRequest(request)).finish()
        #expect(store.schedules.isEmpty && writes.value == 0)
        let approval = try #require(store.pendingManagementApproval)
        #expect(approval.schedule?.scope == .folderContents)
        #expect(store.agentToolReply?.job?.phase == .awaitingConfirmation && store.isBusy)
        await store.send(approve ? .approveManagement(approval.id) : .rejectManagement(approval.id)).finish()
        #expect(store.pendingManagementApproval == nil)
        #expect(writes.value == (approve ? 1 : 0))
        #expect(store.schedules.count == (approve ? 1 : 0))
        #expect(store.agentToolJobs[approval.id]?.phase == (approve ? .succeeded : .cancelled))
    }

    @Test func changedOrRevokedRequestsCannotBeApprovedLater() async throws {
        let policy = LockIsolated(AgentCleanupPolicy.automaticLowRisk)
        let store = ManagementTestSupport.store(ManagementTestSupport.initial()) {
            $0.diskSage.preferences = { CleanupPreferences(agentPolicy: policy.value) }
        }
        var args = ManagementTestSupport.createArguments; args["scope"] = "folderContents"
        let request = try ManagementTestSupport.request("create_schedule", args)
        await store.send(.agentToolRequest(request)).finish()
        policy.setValue(.disabled)
        await store.send(.approveManagement(request.requestID!)).finish()
        #expect(store.schedules.isEmpty)
        #expect(store.agentToolJobs[request.requestID!]?.phase == .failed)
    }

    @Test(arguments: ["missingTiming", "wrongTiming", "past", "presetOverride", "emptyPatch", "validationFailure"])
    func invalidSchedulesDoNotMutateOrBlockExistingRules(scenario: String) async throws {
        var args = ManagementTestSupport.createArguments
        switch scenario {
        case "missingTiming": args["minute"] = nil
        case "wrongTiming": args["weekday"] = 2
        case "past": args = ["target": "npm_cache", "frequency": "once", "run_at": "1969-01-01T00:00:00Z"]
        case "presetOverride": args["target"] = "npm_cache"
        default: break
        }
        let store = ManagementTestSupport.store(ManagementTestSupport.initial()) {
            $0.diskSage.preferences = { CleanupPreferences(agentPolicy: .automaticLowRisk) }
            if scenario == "validationFailure" { $0.schedules.validate = { _ in throw FeatureFailure(message: "Folder is not eligible") } }
        }
        if scenario == "emptyPatch" {
            let create = try ManagementTestSupport.request("create_schedule", args)
            await store.send(.agentToolRequest(create)).finish()
            let value = store.schedules[0]
            let update = try ManagementTestSupport.request("update_schedule", ["schedule_id": value.id.uuidString, "expected_revision": 1], id: 101)
            await store.send(.agentToolRequest(update)).finish()
            #expect(store.schedules == [value])
        } else {
            await store.send(.agentToolRequest(try ManagementTestSupport.request("create_schedule", args))).finish()
            #expect(store.schedules.isEmpty)
        }
        #expect(store.agentToolReply?.error != nil)
        #expect(!store.schedulingBlocked)
    }

    @Test func durableRetriesSurviveRestartAndUiWritesWithoutReapplyingOldConfiguration() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/disksage-schedule-journal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CleanupScheduleRepository(fileURL: root.appending(path: "schedules.json"))
        func store(_ values: [CleanupSchedule]) -> StoreOf<AppFeature> {
            var state = ManagementTestSupport.initial(); state.schedules = values
            return ManagementTestSupport.store(state) {
                $0.diskSage.preferences = { CleanupPreferences(agentPolicy: .automaticLowRisk) }
                $0.management.save = { try repository.save($0, receipt: $1) }
                $0.management.receipt = { id in try repository.receipts().first { $0.request.requestID == id } }
            }
        }
        let create = try ManagementTestSupport.request("create_schedule", ManagementTestSupport.createArguments)
        let first = store([]); await first.send(.agentToolRequest(create)).finish()
        var values = try repository.load(); values[0].isEnabled = false; values[0].revision += 1
        try repository.save(values) // The same path used by UI edits must preserve receipts.
        let reopened = store(try repository.load())
        await reopened.send(.agentToolRequest(create)).finish()
        #expect(reopened.schedules == values && !reopened.schedules[0].isEnabled)
        #expect(reopened.agentToolReply?.data?.object?["replayed"]?.bool == true)
        var conflict = create; conflict.arguments?["hour"] = .integer(8)
        await reopened.send(.agentToolRequest(conflict)).finish()
        #expect(reopened.agentToolReply?.error?.contains("different arguments") == true)
        let remove = try ManagementTestSupport.request("remove_schedule", ["schedule_id": values[0].id.uuidString, "expected_revision": 2], id: 101)
        await reopened.send(.agentToolRequest(remove)).finish()
        let afterRemoval = store(try repository.load())
        await afterRemoval.send(.agentToolRequest(remove)).finish()
        #expect(afterRemoval.schedules.isEmpty && afterRemoval.agentToolReply?.error == nil)
        await afterRemoval.send(.agentToolRequest(.init(action: .job, requestID: remove.requestID))).finish()
        #expect(afterRemoval.agentToolReply?.job?.phase == .succeeded)
        #expect(try repository.receipts().count == 2)
    }

    @Test func malformedStoredTimingCannotCrashACustomFolderApproval() async throws {
        var value = CleanupSchedule(folder: URL(fileURLWithPath: "/fixture/custom"),
            folderIdentity: FileIdentity(device: 1, inode: 2), scope: .folderContents, weekday: 0, isEnabled: false)
        value.revision = 1
        var state = ManagementTestSupport.initial(); state.schedules = [value]
        let store = ManagementTestSupport.store(state) { $0.diskSage.preferences = { CleanupPreferences(agentPolicy: .automaticLowRisk) } }
        let request = try ManagementTestSupport.request("update_schedule", ["schedule_id": value.id.uuidString, "expected_revision": 1, "enabled": false])
        await store.send(.agentToolRequest(request)).finish()
        #expect(store.pendingManagementApproval == nil && store.schedules == [value])
        #expect(store.agentToolReply?.error?.contains("timing is invalid") == true)
    }
}
