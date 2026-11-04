import Foundation
import Testing
@testable import DiskSage

struct SafetyPolicyTests {
    private let policy = SafetyPolicy()

    @Test
    func allowsDerivedData() throws {
        let candidate = CleanupCandidate(
            url: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Developer/Xcode/DerivedData"),
            name: "DerivedData",
            category: .build,
            size: 1,
            risk: .low,
            reason: "Generated"
        )
        try policy.validate(candidate)
    }

    @Test
    func rejectsGitData() {
        let candidate = CleanupCandidate(
            url: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Developer/App/.git/objects"),
            name: "objects",
            category: .cache,
            size: 1,
            risk: .low,
            reason: "Unsafe"
        )
        #expect(throws: SafetyPolicyError.self) {
            try policy.validate(candidate)
        }
    }

    @Test
    func rejectsUnknownDirectory() {
        let candidate = CleanupCandidate(
            url: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents"),
            name: "Documents",
            category: .cache,
            size: 1,
            risk: .low,
            reason: "Unsafe"
        )
        #expect(throws: SafetyPolicyError.self) {
            try policy.validate(candidate)
        }
    }

    @Test
    func rejectsDirectoryContainingRunningExecutable() throws {
        let executable = try #require(Bundle.main.executableURL)
        let candidate = CleanupCandidate(
            url: executable.deletingLastPathComponent(),
            name: "Running binary folder",
            category: .build,
            size: 1,
            risk: .low,
            reason: "Unsafe while running"
        )
        #expect(throws: SafetyPolicyError.self) {
            try policy.validate(candidate)
        }
    }
}
