import Foundation
import Testing
@testable import DiskSage

struct TemporaryBuildTests {
    @Test func derivedDataIsFoundByLayout() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let derived = try f.derivedData("app-derived")
        #expect(TemporaryBuildOutput.kind(of: derived, home: f.home) == .derivedData)
        try f.write("only-build/Build/Products/a.o")
        #expect(TemporaryBuildOutput.kind(of: f.base.appending(path: "only-build"), home: f.home) == nil)
        try f.write("no-plist/Build/a.o"); try f.write("no-plist/Logs/a.log")
        #expect(TemporaryBuildOutput.kind(of: f.base.appending(path: "no-plist"), home: f.home) == nil)
        let outside = URL(fileURLWithPath: "/Users/disksage-fixture/Developer/app/DerivedData")
        #expect(TemporaryBuildOutput.kind(of: outside, home: f.home) == nil)
    }

    @Test func looseBundlesAreFoundOnlyNearTheTopOfTmp() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write("Run.xcresult/Info.plist")
        try f.write("Shot.app/Info.plist")
        try f.write("deep/Nested.xcresult/Info.plist")
        try f.write("deep/deeper/Hidden.xcresult/Info.plist")
        #expect(TemporaryBuildOutput.kind(of: f.base.appending(path: "Run.xcresult"), home: f.home) == .resultBundle)
        #expect(TemporaryBuildOutput.kind(of: f.base.appending(path: "Shot.app"), home: f.home) == .appBundle)
        #expect(TemporaryBuildOutput.kind(of: f.base.appending(path: "deep/Nested.xcresult"), home: f.home) == nil)
        // The search depth counts from the folder it gets; kind(of:) counts from /private/tmp.
        let found = Set(TemporaryBuildInspector.looseBundles(in: f.base).map(\.lastPathComponent))
        #expect(found == ["Run.xcresult", "Shot.app", "Nested.xcresult"])
    }

    @Test func riskFollowsIdleTime() {
        let hour = 3_600.0
        #expect(TemporaryBuildOutput.risk(.derivedData, idle: hour) == nil)
        #expect(TemporaryBuildOutput.risk(.derivedData, idle: 7 * hour) == .medium)
        #expect(TemporaryBuildOutput.risk(.derivedData, idle: 25 * hour) == .low)
        #expect(TemporaryBuildOutput.risk(.resultBundle, idle: 23 * hour) == nil)
        #expect(TemporaryBuildOutput.risk(.appBundle, idle: 25 * hour) == .medium)
        #expect(TemporaryBuildOutput.risk(.scratchpad, idle: 48 * hour) == nil)
        #expect(TemporaryBuildOutput.risk(.scratchpad, idle: 100 * hour) == .medium)
    }

    @Test func idleDerivedDataIsOfferedAsWholeFolderAndDeleted() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let derived = try f.derivedData("app-derived")
        try f.write("app-derived/SourcePackages/checkouts/package/.git/HEAD")
        #expect(TemporaryBuildInspector.inspect(derived, activity: .idle, now: f.later(hours: 1), home: f.home) == nil)
        let medium = try #require(TemporaryBuildInspector.inspect(derived, activity: .idle, now: f.later(hours: 8), home: f.home))
        #expect(medium.risk == .medium)
        let low = try #require(TemporaryBuildInspector.inspect(derived, activity: .idle, now: f.later(hours: 25), home: f.home))
        #expect(low.risk == .low && low.deletionMode == .item && low.size >= 6 * 4_096)
        #expect(throws: (any Error).self) {
            try TemporaryBuildInspector.verifyBeforeDeletion(low, activity: .idle, now: f.later(hours: 8), home: f.home)
        }
        try TemporaryBuildInspector.verifyBeforeDeletion(low, activity: .idle, now: f.later(hours: 25), home: f.home)
        try SecureFileDeleter.delete(low, entryRemoved: {})
        #expect(!f.exists(derived))
    }

    @Test func gitDataOutsideSourcePackagesIsNeverOffered() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let derived = try f.derivedData("work-derived")
        try f.write("work-derived/Build/notes/.git/HEAD")
        #expect(TemporaryBuildInspector.inspect(derived, activity: .idle, now: f.later(hours: 30), home: f.home) == nil)
    }

    @Test func folderInUseOrChangedIsRefused() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let derived = try f.derivedData("app-derived")
        let busy = CleanupActivity(paths: [derived.appending(path: "Logs/Build").path])
        #expect(TemporaryBuildInspector.inspect(derived, activity: busy, now: f.later(hours: 30), home: f.home) == nil)
        let target = try #require(TemporaryBuildInspector.inspect(derived, activity: .idle, now: f.later(hours: 30), home: f.home))
        #expect(throws: FeatureFailure.self) {
            try TemporaryBuildInspector.verifyBeforeDeletion(target, activity: busy, now: f.later(hours: 30), home: f.home)
        }
        try FileManager.default.removeItem(at: derived.appending(path: "info.plist"))
        #expect(throws: FeatureFailure.self) {
            try TemporaryBuildInspector.verifyBeforeDeletion(target, activity: .idle, now: f.later(hours: 30), home: f.home)
        }
    }

    /// A folder that a running xcodebuild names as `-derivedDataPath` is never a candidate,
    /// even when it looks old enough.
    @Test func runningBuildDerivedDataPathIsNeverAWholeFolderCandidate() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let derived = try f.derivedData("live-derived")
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/bin/sh")
        build.arguments = ["-c", "while :; do sleep 0.2; done", "xcodebuild", "-derivedDataPath", derived.path]
        try build.run()
        defer { build.terminate(); build.waitUntilExit() }
        var activity = CleanupActivity.idle
        for _ in 0..<50 where !activity.contains(derived) {
            activity = CleanupActivity(paths: try ProcessArgumentPaths.capture())
            Thread.sleep(forTimeInterval: 0.1)
        }
        #expect(activity.contains(derived))
        #expect(TemporaryBuildInspector.inspect(derived, activity: activity, now: f.later(hours: 48), home: f.home) == nil)
        let result = TemporaryBuildInspector.scan(discovered: [derived], activity: activity, now: f.later(hours: 48),
            home: f.home, extraFolders: { [] })
        #expect(result.candidates.isEmpty)
    }

    @Test func policyAcceptsOnlyWholeFolderDeletionOfTemporaryOutput() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let derived = try f.derivedData("app-derived")
        let target = try #require(TemporaryBuildInspector.inspect(derived, activity: .idle, now: f.later(hours: 30), home: f.home))
        let contents = CleanupCandidate(url: target.url, name: target.name, category: .build, size: target.size,
            risk: .low, reason: "Contents", identity: target.identity, deletionMode: .contents)
        #expect(throws: SafetyPolicyError.self) { try SafetyPolicy(home: f.home).validate(contents) }
        let plain = try f.folder("plain")
        let other = CleanupCandidate(url: plain, name: "plain", category: .build, size: 1, risk: .low, reason: "Plain")
        #expect(throws: SafetyPolicyError.self) { try SafetyPolicy(home: f.home).validate(other) }
    }
}
