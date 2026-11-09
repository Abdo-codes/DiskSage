import Foundation
import Testing
@testable import DiskSage

struct ClaudeSessionTests {
    /// A fake project under the real `/private/tmp/claude-<uid>` root, removed after each test.
    private func fixture() throws -> TemporaryBuildFixture {
        try TemporaryBuildFixture(base: TemporaryBuildOutput.claudeRoot.appending(path: "DS-session-test-\(UUID())"))
    }

    @Test func sessionFolderIsFoundFromAnyPathInside() {
        let root = TemporaryBuildOutput.claudeRoot.path
        let session = ClaudeSessionActivity.session(containing: URL(fileURLWithPath: "\(root)/project/abc/scratchpad/dd/Build"))
        #expect(session?.path == "\(root)/project/abc")
        #expect(ClaudeSessionActivity.session(containing: URL(fileURLWithPath: "\(root)/lane-dd")) == nil)
        #expect(ClaudeSessionActivity.session(containing: URL(fileURLWithPath: "/private/tmp/other/a/b")) == nil)
    }

    @Test func recentOrUsedSessionIsLive() throws {
        let f = try fixture(); defer { f.remove() }
        let session = try f.folder("abc")
        try f.write("abc/scratchpad/notes.md")
        #expect(ClaudeSessionActivity.isLive(session, activity: .idle, now: f.later(hours: 1)))
        #expect(!ClaudeSessionActivity.isLive(session, activity: .idle, now: f.later(hours: 25)))
        let used = CleanupActivity(paths: [session.appending(path: "tasks/run.output").path])
        #expect(ClaudeSessionActivity.isLive(session, activity: used, now: f.later(hours: 25)))
    }

    @Test func scratchpadIsOfferedOnlyForReviewAfterThreeDays() throws {
        let f = try fixture(); defer { f.remove() }
        try f.write("abc/scratchpad/result.json")
        let scratchpad = CleanupPath.fileURL(f.base.appending(path: "abc/scratchpad"))
        #expect(TemporaryBuildOutput.kind(of: scratchpad) == .scratchpad)
        #expect(ClaudeSessionActivity.scratchpads().contains(scratchpad))
        #expect(TemporaryBuildInspector.inspect(scratchpad, activity: .idle, now: f.later(hours: 48)) == nil)
        let target = try #require(TemporaryBuildInspector.inspect(scratchpad, activity: .idle, now: f.later(hours: 80)))
        #expect(target.risk == .medium && target.deletionMode == .item)
        try f.write("abc/scratchpad/clone/.git/HEAD")
        #expect(TemporaryBuildInspector.inspect(scratchpad, activity: .idle, now: f.later(hours: 80)) == nil)
    }

    @Test func liveSessionKeepsEvenCompiledFiles() throws {
        let f = try fixture(); defer { f.remove() }
        let derived = try f.derivedData("abc/scratchpad/dd")
        let live = TemporaryBuildInspector.scan(discovered: [derived], activity: .idle, now: f.later(hours: 2), extraFolders: { [] })
        #expect(live.candidates.isEmpty && live.generatedRoots.isEmpty)
        let scratchpad = CleanupPath.fileURL(f.base.appending(path: "abc/scratchpad"))
        let stale = TemporaryBuildInspector.scan(discovered: [derived], activity: .idle, now: f.later(hours: 30),
            extraFolders: { [scratchpad] })
        // After a day the build folder can go automatically; the scratchpad still waits for three days.
        #expect(stale.candidates.map(\.url) == [derived])
        #expect(stale.candidates.first?.risk == .low)
        let target = try #require(stale.candidates.first)
        try TemporaryBuildInspector.verifyBeforeDeletion(target, activity: .idle, now: f.later(hours: 30))
        // A session that is live again at deletion time blocks the deletion.
        #expect(throws: FeatureFailure.self) {
            try TemporaryBuildInspector.verifyBeforeDeletion(target, activity: .idle, now: f.later(hours: 2))
        }
    }

    @Test func staleScratchpadCoversTheBuildFoldersInside() throws {
        let f = try fixture(); defer { f.remove() }
        let derived = try f.derivedData("abc/scratchpad/dd")
        let generated = try f.folder("abc/scratchpad/tool/.build")
        let scratchpad = CleanupPath.fileURL(f.base.appending(path: "abc/scratchpad"))
        let result = TemporaryBuildInspector.scan(discovered: [derived, generated], activity: .idle,
            now: f.later(hours: 80), extraFolders: { [scratchpad] })
        #expect(result.candidates.map(\.url) == [scratchpad])
        #expect(result.generatedRoots.isEmpty)
    }
}
