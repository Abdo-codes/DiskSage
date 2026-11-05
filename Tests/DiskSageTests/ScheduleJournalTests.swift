import Foundation
import Testing
@testable import DiskSage

struct ScheduleJournalTests {
    @Test func legacyScheduleArraysMigrateWithoutDroppingConfigurationAndReceiptsAreBounded() throws {
        let root = URL(fileURLWithPath: "/private/tmp/disksage-journal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = CleanupScheduleRepository(fileURL: root.appending(path: "schedules.json"))
        let schedule = CleanupSchedule(folder: URL(fileURLWithPath: "/fixture/cache"), folderIdentity: FileIdentity(device: 1, inode: 2))
        try JSONEncoder().encode([schedule]).write(to: repository.fileURL)
        #expect(try repository.load() == [schedule])
        try repository.save([schedule])
        #expect(try repository.load() == [schedule] && repository.receipts().isEmpty)
        struct Document: Codable { var version = 1; var schedules: [CleanupSchedule]; var receipts: [ToolMutationReceipt] }
        let old = (0..<200).map { _ in
            ToolMutationReceipt(request: .init(action: .manage, requestID: UUID(), tool: "pause_schedule", arguments: [:]),
                result: .object(["paused": .bool(true)]), timestamp: Date(timeIntervalSince1970: 0))
        }
        try JSONEncoder().encode(Document(schedules: [schedule], receipts: old)).write(to: repository.fileURL)
        let fresh = ToolMutationReceipt(request: .init(action: .manage, requestID: UUID(), tool: "remove_schedule", arguments: [:]),
            result: .object(["removed": .bool(true)]), timestamp: Date(timeIntervalSince1970: 1))
        try repository.save([], receipt: fresh)
        #expect(try repository.load().isEmpty)
        let retained = try repository.receipts()
        #expect(retained.count == 200 && retained.first == old[1] && retained.last == fresh)
        #expect(throws: FeatureFailure.self) { try repository.save([], receipt: fresh) }
        #expect(try repository.receipts() == retained)
    }
}
