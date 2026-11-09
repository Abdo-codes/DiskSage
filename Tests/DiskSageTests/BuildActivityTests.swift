import Foundation
import Testing
@testable import DiskSage

struct BuildActivityTests {
    @Test func argumentPathsKeepPathsAndSkipFlags() {
        let paths = ProcessArgumentPaths.paths(arguments: [
            "xcodebuild", "test", "-derivedDataPath", "/tmp/build/dd", "SYMROOT=/var/out/../sym",
            "-scheme", "-destination=platform=iOS", "relative/dd", "NAME=value", "/"
        ], workingDirectory: "/private/tmp/work")
        #expect(paths.contains("/private/tmp/build/dd"))
        #expect(paths.contains("/private/var/sym"))
        #expect(paths.contains("/private/tmp/work/test"))
        #expect(paths.contains("/private/tmp/work/relative/dd"))
        #expect(!paths.contains { $0.contains("-") || $0.contains("=") || $0 == "/" })
        #expect(!paths.contains("/private/tmp/work/xcodebuild"))
        #expect(ProcessArgumentPaths.paths(arguments: ["tool", "relative"], workingDirectory: nil).isEmpty)
    }

    @Test func ownArgumentsAreReadable() throws {
        let own = try #require(ProcessArgumentPaths.arguments(of: getpid()))
        #expect(!own.isEmpty)
    }

    /// The live failure: an xcodebuild between compile steps has no open files in its
    /// `-derivedDataPath`, and DiskSage deleted that build's older outputs.
    @Test func runningBuildDerivedDataPathIsNeverACandidate() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        try f.write("Build/Intermediates.noindex/App.build/a.o")
        #expect(try f.candidate() != nil)

        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/bin/sh")
        build.arguments = ["-c", "while :; do sleep 0.2; done", "xcodebuild", "test", "-derivedDataPath", f.root.path]
        try build.run()
        defer { build.terminate(); build.waitUntilExit() }
        try waitForArguments(naming: f.root)

        // capture() adds these paths to the open files from lsof; a full lsof is too slow for a unit test.
        let activity = CleanupActivity(paths: try ProcessArgumentPaths.capture())
        #expect(activity.contains(f.root))
        #expect(throws: FeatureFailure.self) {
            try GeneratedFileDeleter.inspect(f.root, name: "Live", category: .build, rule: .buildArtifacts,
                activity: activity, cutoff: f.cutoff, policy: f.policy)
        }
        let target = try #require(try f.candidate())
        #expect(throws: FeatureFailure.self) {
            try GeneratedFileDeleter.delete(target, policy: f.policy, activity: { CleanupActivity(paths: try ProcessArgumentPaths.capture()) },
                entryRemoved: {})
        }
        #expect(f.exists("Build/Intermediates.noindex/App.build/a.o"))
    }

    @Test func recentWriteKeepsWholeBuildFolder() throws {
        let f = try GeneratedCleanupFixture(); defer { f.remove() }
        try f.write("Build/Intermediates.noindex/App.build/old.o")
        let cutoff = try pause()
        try f.write("Build/Intermediates.noindex/App.build/new.d")
        let idle = try GeneratedFileInventory.read(f.root, rule: .buildArtifacts, cutoff: cutoff)
        #expect(idle.entries.map(\.path) == ["Build/Intermediates.noindex/App.build/old.o"])
        let busy = try GeneratedFileInventory.read(f.root, rule: .buildArtifacts, cutoff: cutoff, activity: .wholeRoot)
        #expect(busy.entries.isEmpty)
    }

    @Test func recentWriteInSharedRootKeepsOnlyThatProject() throws {
        let f = try GeneratedCleanupFixture(relative: "Library/Developer/Xcode/DerivedData"); defer { f.remove() }
        try f.write("Idle-abc/Build/Intermediates.noindex/a.o")
        try f.write("Busy-def/Build/Intermediates.noindex/b.o")
        let cutoff = try pause()
        try f.write("Busy-def/Logs/Build/current.xcactivitylog")
        let inventory = try GeneratedFileInventory.read(f.root, rule: .buildArtifacts, cutoff: cutoff, activity: .perChild)
        #expect(inventory.entries.map(\.path) == ["Idle-abc/Build/Intermediates.noindex/a.o"])
    }

    @Test func activityScopeFollowsRootKind() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let derived = home.appending(path: "Library/Developer/Xcode/DerivedData")
        #expect(GeneratedActivityScope.of(derived, rule: .buildArtifacts, home: home) == .perChild)
        #expect(GeneratedActivityScope.of(URL(fileURLWithPath: "/private/tmp/app-dd"), rule: .buildArtifacts,
            home: home) == .wholeRoot)
        #expect(GeneratedActivityScope.of(home.appending(path: ".npm/_cacache"), rule: .npmContent, home: home) == .none)
    }

    /// Returns a cutoff strictly between files written before and after the call.
    private func pause() throws -> Date {
        Thread.sleep(forTimeInterval: 0.05)
        let cutoff = Date()
        Thread.sleep(forTimeInterval: 0.05)
        return cutoff
    }

    private func waitForArguments(naming root: URL) throws {
        let path = CleanupPath.fileURL(root).path
        for _ in 0..<50 {
            if try ProcessArgumentPaths.capture().contains(path) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        Issue.record("The build process arguments were never visible.")
    }
}
