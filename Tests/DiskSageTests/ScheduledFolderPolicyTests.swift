import Foundation
import Testing
@testable import DiskSage

struct ScheduledFolderPolicyTests {
    private struct Fixture {
        let root: URL
        let folder: URL
        let repository: CleanupScheduleRepository
        let logger: CleanupLogger
        var schedule: CleanupSchedule

        init() throws {
            root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appending(path: "DiskSage-scheduled-fixture-\(UUID())")
            folder = root.appending(path: "authorized")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("Disposable fixture".utf8).write(to: folder.appending(path: "entry.txt"))
            repository = CleanupScheduleRepository(fileURL: root.appending(path: "settings/schedules.json"))
            logger = CleanupLogger(directory: root.appending(path: "logs"))
            schedule = CleanupSchedule(folder: folder, folderIdentity: try ScheduledFolderPolicy.identity(of: folder),
                scope: .folderContents)
            try repository.save([schedule])
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func customAuthorizationUsesSecureDeletionPreservesFolderAndLogsScheduledTrigger() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let outside = fixture.root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("Keep".utf8).write(to: outside.appending(path: "keep.txt"))
        try FileManager.default.createSymbolicLink(at: fixture.folder.appending(path: "link"), withDestinationURL: outside)
        let targets = try ScheduledFolderPolicy.scan(fixture.schedule, activity: { .idle })
        let report = await ScheduledFolderPolicy.delete(fixture.schedule, candidates: targets,
            repository: fixture.repository, logger: fixture.logger, progress: { _ in })
        #expect(report.failures.isEmpty && report.loggingError == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: outside.appending(path: "keep.txt").path))
        let history = try fixture.logger.recentCleanups()
        #expect(history.count == 1 && history[0].trigger == .scheduled)
        #expect(history[0].items.first?.path == fixture.folder.path)
    }

    @Test(arguments: ["paused", "removed", "scope", "identity", "outsideTarget"])
    func revokedOrChangedAuthorizationNeverDeletes(scenario: String) async throws {
        var fixture = try Fixture(); defer { fixture.remove() }
        var targets = try ScheduledFolderPolicy.scan(fixture.schedule, activity: { .idle })
        switch scenario {
        case "paused": fixture.schedule.isEnabled = false
        case "removed": try fixture.repository.save([])
        case "scope": fixture.schedule.scope = .lowRisk
        case "identity": fixture.schedule.folderIdentity = FileIdentity(device: 0, inode: 0)
        default:
            targets = [CleanupCandidate(url: fixture.root, name: "Unauthorized parent", category: .cache,
                size: 1, risk: .medium, reason: "Fixture", identity: fixture.schedule.folderIdentity, deletionMode: .contents)]
        }
        if scenario != "removed" { try fixture.repository.save([fixture.schedule]) }
        let original = CleanupSchedule(id: fixture.schedule.id, folder: fixture.folder,
            folderIdentity: try ScheduledFolderPolicy.identity(of: fixture.folder), scope: .folderContents)
        let report = await ScheduledFolderPolicy.delete(original, candidates: targets,
            repository: fixture.repository, logger: fixture.logger, progress: { _ in })
        #expect(report.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.folder.appending(path: "entry.txt").path))
    }

    @Test func customFoldersRequireExplicitScopeAndReplacedFoldersRequireNewAuthorization() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var low = fixture.schedule; low.scope = .lowRisk
        #expect(throws: FeatureFailure.self) { try ScheduledFolderPolicy.scan(low, activity: { .idle }) }
        // Keep the original inode alive so this cannot accidentally test inode reuse.
        try FileManager.default.moveItem(at: fixture.folder, to: fixture.root.appending(path: "old"))
        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: true)
        #expect(throws: FeatureFailure.self) { try ScheduledFolderPolicy.validate(fixture.schedule) }
    }

    @Test func symlinkedRootsAndBroadDirectoriesAreRejected() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let link = fixture.root.appending(path: "linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.folder)
        let home = FileManager.default.homeDirectoryForCurrentUser
        for url in [link, home, home.appending(path: "Developer"), URL(fileURLWithPath: "/"),
                    URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Library"),
                    home.appending(path: "Library/Application Support/DiskSage"),
                    home.appending(path: "Library/Logs/DiskSage")] {
            #expect(throws: FeatureFailure.self) { try ScheduledFolderPolicy.identity(of: url) }
        }
        let executable = try #require(Bundle.main.executableURL)
        #expect(throws: FeatureFailure.self) {
            try ScheduledFolderPolicy.identity(of: executable.deletingLastPathComponent())
        }
    }

    @Test func lowRiskScheduleKeepsRecentAndUnrecognizedFiles() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appending(path: "Developer/.disksage-schedule-test-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: ".build", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "debug"), withIntermediateDirectories: true)
        try Data("recent".utf8).write(to: folder.appending(path: "debug/recent.o"))
        try Data("evidence".utf8).write(to: folder.appending(path: "run.log"))
        let value = CleanupSchedule(folder: folder, folderIdentity: try ScheduledFolderPolicy.identity(of: folder))
        #expect(try ScheduledFolderPolicy.scan(value, activity: { .idle }).isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "run.log").path))
        let unknown = home.appending(path: "Library/Caches/UnknownApp")
        #expect(throws: FeatureFailure.self) { try ScheduledFolderPolicy.lowRiskCategory(unknown) }
    }
}
