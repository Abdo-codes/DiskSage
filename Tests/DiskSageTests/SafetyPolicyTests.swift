import Foundation
import Darwin
import Testing
@testable import DiskSage

struct SafetyPolicyTests {
    private let policy = SafetyPolicy()

    @Test
    func allowsDerivedData() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let candidate = CleanupCandidate(
            url: fixture.root.appending(path: "Library/Developer/Xcode/DerivedData", directoryHint: .isDirectory),
            name: "DerivedData",
            category: .build,
            size: 1,
            risk: .low,
            reason: "Generated"
        )
        try FileManager.default.createDirectory(at: candidate.url, withIntermediateDirectories: true)
        try SafetyPolicy(home: fixture.root).validate(candidate)
        // The same allowlisted cache container must refuse nested checkout data.
        try FileManager.default.createDirectory(at: candidate.url.appending(path: "SourcePackages/checkouts/dependency/.git"), withIntermediateDirectories: true)
        #expect(throws: SafetyPolicyError.self) { try SafetyPolicy(home: fixture.root).validate(candidate) }
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

    @Test func deniesUnknownScopeBeforeInspectingItsContents() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let folder = fixture.root.appending(path: "Documents")
        try FileManager.default.createDirectory(at: folder.appending(path: ".git"), withIntermediateDirectories: true)
        let candidate = CleanupCandidate(url: folder, name: "Unknown", category: .cache, size: 1, risk: .low, reason: "Unsafe")
        do {
            try SafetyPolicy(home: fixture.root).validate(candidate)
            Issue.record("Unknown scope must be denied")
        } catch {
            #expect(error.localizedDescription == "The path is outside DiskSage’s cleanup allowlist.")
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

    @Test
    func rejectsSymlinkedAncestor() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let external = FileManager.default.temporaryDirectory
            .appending(path: "DiskSage-external-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: external) }
        let build = external.appending(path: "build", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let link = fixture.root.appending(path: "linked-project")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)

        let candidate = CleanupCandidate(
            url: link.appending(path: "build", directoryHint: .isDirectory),
            name: "build",
            category: .build,
            size: 1,
            risk: .medium,
            reason: "Fixture"
        )
        #expect(throws: SafetyPolicyError.self) {
            try policy.validate(candidate)
        }
    }

    @Test
    func rejectsChangedIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let build = fixture.root.appending(path: "build", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)

        let candidate = CleanupCandidate(
            url: build,
            name: "build",
            category: .build,
            size: 1,
            risk: .medium,
            reason: "Fixture",
            identity: FileIdentity(device: UInt64.max, inode: UInt64.max)
        )
        #expect(throws: SafetyPolicyError.self) {
            try policy.validate(candidate)
        }
    }

    private struct Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Developer/.disksage-test-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
