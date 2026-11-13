import Foundation
import Testing
@testable import DiskSage

@Suite(.serialized)
struct WorktreeDiscoveryLimitTests {
    private func service(_ fixture: WorktreeFixture, limit: Int) -> WorktreeService {
        WorktreeService(inspector: WorktreeInspector(checkActivity: false),
                        repository: WorktreeRepository(url: fixture.root.appending(path: "journal.json")),
                        logger: CleanupLogger(directory: fixture.root.appending(path: "logs")), discoveryFolderLimit: limit)
    }

    @Test func looseFilesDoNotCountAgainstTheFolderLimit() throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        let loose = fixture.root.appending(path: "loose")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        for index in 0..<200 { try "x".write(to: loose.appending(path: "file-\(index)"), atomically: true, encoding: .utf8) }
        let inventory = try service(fixture, limit: 10).inventory(fixture.configuration)
        #expect(inventory.items.contains { $0.worktree.path == fixture.checkout.path })
        #expect(inventory.warnings.isEmpty, "\(inventory.warnings)")
    }

    @Test func folderLimitGivesAWarningAndNoFailure() throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        let inventory = try service(fixture, limit: 0).inventory(fixture.configuration)
        #expect(inventory.items.isEmpty)
        #expect(inventory.warnings.contains { $0.contains("more than 0 folders") })
    }
}
