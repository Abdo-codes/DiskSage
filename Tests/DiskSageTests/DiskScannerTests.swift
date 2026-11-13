import Foundation
import Testing
@testable import DiskSage

struct DiskScannerTests {
    @Test func everyScannedCandidatePassesDeletionPolicy() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Developer/.disksage-scanner-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = [root.appending(path: "Project/.build", directoryHint: .isDirectory), root.appending(path: "Other/build", directoryHint: .isDirectory), root.appending(path: "Unrecognized", directoryHint: .isDirectory)]
        for path in paths {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: path.appending(path: "artifact"))
        }
        let locations = paths.map {
            DiskScanner.Location(url: $0, name: $0.lastPathComponent, category: .build, risk: .low,
                                 reason: "Generated fixture", deletionMode: .item)
        }
        let candidates = try await DiskScanner(locations: locations).scan()
        #expect(Set(candidates.map(\.url)) == Set(paths.prefix(2)))
        for candidate in candidates { try SafetyPolicy().validate(candidate) }
    }

    @Test func scannerNeverOffersItsOwnExecutableTree() async throws {
        let executable = try #require(Bundle.main.executableURL?.standardizedFileURL)
        let location = DiskScanner.Location(url: executable.deletingLastPathComponent(), name: "Running app",
            category: .build, risk: .low, reason: "Fixture", deletionMode: .item)
        let candidates = try await DiskScanner(locations: [location]).scan()
        #expect(candidates.isEmpty)
    }

    @Test func packageDirectoriesContributeTheirContentsToSize() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DiskSage-size-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appending(path: "Example.app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 64 * 1024).write(to: resources.appending(path: "payload.bin"))
        #expect(try #require(DiskScanner.allocatedSize(of: root)) >= 64 * 1024)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DISKSAGE_LIVE_SCAN_TEST"] == "1"))
    func liveScanCandidatesPassPolicyOnThisMac() async throws {
        let candidates = try await DiskScanner().scan()
        for candidate in candidates {
            do { try SafetyPolicy().validate(candidate) }
            catch { Issue.record(error, Comment(rawValue: "Candidate: \(candidate.url.path)")) }
        }
    }
}
