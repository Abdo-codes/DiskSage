import Foundation
import Testing
@testable import DiskSage

struct CleanupScheduleTests {
    private func calendar(_ zone: String = "Europe/Amsterdam") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func schedule() -> CleanupSchedule {
        CleanupSchedule(folder: URL(fileURLWithPath: "/fixture/cache"),
            folderIdentity: FileIdentity(device: 1, inode: 2))
    }

    @Test(arguments: ["Europe/Amsterdam", "America/New_York", "UTC"])
    func dailyUsesLocalWallClockAndNeverRepeatsAnOccurrence(zone: String) throws {
        let calendar = calendar(zone)
        var value = schedule(); value.hour = 14; value.minute = 25
        let first = try #require(value.nextOccurrence(after: date("2026-11-05T00:00:00Z"), calendar: calendar))
        #expect(calendar.component(.hour, from: first) == 14)
        #expect(calendar.component(.minute, from: first) == 25)
        let next = try #require(value.nextOccurrence(after: first, calendar: calendar))
        #expect(calendar.dateComponents([.day], from: first, to: next).day == 1)
    }

    @Test func weeklyFindsTheChosenWeekdayAndMissedRunsAdvanceBeyondNow() throws {
        var value = schedule(); value.frequency = .weekly; value.weekday = 2; value.hour = 9
        let calendar = calendar()
        let next = try #require(value.nextOccurrence(after: date("2026-11-05T18:00:00Z"), calendar: calendar))
        #expect(next == date("2026-11-09T08:00:00Z"))
        #expect(value.nextOccurrence(after: next, calendar: calendar) == date("2026-11-16T08:00:00Z"))
    }

    @Test func daylightSavingGapMovesForwardAndRepeatedTimeDoesNotRunTwice() throws {
        var value = schedule(); value.hour = 2; value.minute = 30
        let calendar = calendar()
        let spring = try #require(value.nextOccurrence(after: date("2027-03-28T00:00:00Z"), calendar: calendar))
        #expect(calendar.component(.day, from: spring) == 28)
        #expect(calendar.component(.hour, from: spring) == 3)
        let fall = try #require(value.nextOccurrence(after: date("2027-10-31T00:00:00Z"), calendar: calendar))
        let following = try #require(value.nextOccurrence(after: fall, calendar: calendar))
        #expect(calendar.component(.day, from: following) == 1)
    }

    @Test func oneTimeAndInvalidTimesCannotRescheduleInThePast() {
        var value = schedule(); value.frequency = .once
        value.oneTimeDate = date("2026-11-05T12:00:00Z")
        #expect(value.nextOccurrence(after: date("2026-11-05T11:59:00Z")) == value.oneTimeDate)
        #expect(value.nextOccurrence(after: value.oneTimeDate) == nil)
        value.frequency = .daily; value.hour = 24
        #expect(value.nextOccurrence(after: .now) == nil)
    }

    @Test func persistenceRoundTripsClaimsAndRejectsCorruptionWithoutReplacingIt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DiskSage-schedules-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CleanupScheduleRepository(fileURL: root.appending(path: "schedules.json"))
        #expect(try repository.load().isEmpty)
        var value = schedule(); value.nextRun = date("2026-11-06T01:00:00Z"); value.lastResult = "Previous run"
        try repository.save([value])
        #expect(try repository.load() == [value])
        let permissions = try FileManager.default.attributesOfItem(atPath: repository.fileURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        try Data("invalid".utf8).write(to: repository.fileURL)
        #expect(throws: (any Error).self) { try repository.load() }
        #expect(try String(contentsOf: repository.fileURL, encoding: .utf8) == "invalid")
        #expect(throws: (any Error).self) { try repository.save([value]) }
        try FileManager.default.removeItem(at: repository.fileURL)
        #expect(throws: FeatureFailure.self) { try repository.save([value, value]) }
        // A legacy array with duplicate IDs is also rejected on load.
        try JSONEncoder().encode([value, value]).write(to: repository.fileURL)
        #expect(throws: FeatureFailure.self) { try repository.load() }
    }
}
