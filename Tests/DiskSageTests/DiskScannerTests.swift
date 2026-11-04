import Foundation
import Testing
@testable import DiskSage

struct DiskScannerTests {
    @Test
    func everyScannedCandidatePassesDeletionPolicy() async throws {
        let candidates = await DiskScanner().scan()
        let policy = SafetyPolicy()

        for candidate in candidates {
            try policy.validate(candidate)
        }
    }

    @Test
    func scannerNeverOffersItsOwnExecutableTree() async throws {
        let executable = try #require(Bundle.main.executableURL?.standardizedFileURL)
        let candidates = await DiskScanner().scan()

        #expect(candidates.allSatisfy { candidate in
            !executable.path.hasPrefix(candidate.url.standardizedFileURL.path + "/")
        })
    }

    @Test
    func packageDirectoriesContributeTheirContentsToSize() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "DiskSage-size-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Example.app", directoryHint: .isDirectory)
        let resources = app.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 64 * 1024)
            .write(to: resources.appending(path: "payload.bin"))

        let size = try #require(DiskScanner.allocatedSize(of: root))
        #expect(size >= 64 * 1024)
    }
}
