import Darwin
import Foundation
import Testing
@testable import DiskSage

/// The fixture folder stands in for the home folder, so `~/.codex` and `~/Documents/Codex` are inside it.
struct AgentWorkspaceTests {
    @Test func codexDayFoldersAreFoundOnlyAtDayDepth() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let day = try f.folder(".codex/visualizations/2026/10/22")
        let session = try f.folder(".codex/sessions/2026/10/22")
        let month = try f.folder(".codex/visualizations/2026/10")
        let named = try f.folder(".codex/visualizations/2026/10/ab")
        #expect(TemporaryBuildOutput.kind(of: day, home: f.base) == .codexVisualizationDay)
        #expect(TemporaryBuildOutput.kind(of: session, home: f.base) == .codexSessionDay)
        #expect(TemporaryBuildOutput.kind(of: month, home: f.base) == nil)
        #expect(TemporaryBuildOutput.kind(of: named, home: f.base) == nil)
        #expect(Set(AgentWorkspaceDiscovery.codexDays(home: f.base)) == [day, session, named])
    }

    @Test func codexRiskFollowsIdleTime() {
        let d = TemporaryBuildOutput.day
        #expect(TemporaryBuildOutput.risk(.codexVisualizationDay, idle: 12 * TemporaryBuildOutput.hour) == nil)
        #expect(TemporaryBuildOutput.risk(.codexVisualizationDay, idle: 2 * d) == .medium)
        #expect(TemporaryBuildOutput.risk(.codexVisualizationDay, idle: 8 * d) == .low)
        #expect(TemporaryBuildOutput.risk(.codexSessionDay, idle: 3 * d) == nil)
        #expect(TemporaryBuildOutput.risk(.codexSessionDay, idle: 8 * d) == .medium)
        #expect(TemporaryBuildOutput.risk(.swiftPackages, idle: 2 * d) == .low)
    }

    @Test func idleCodexDayIsOfferedAndPassesTheChecksBeforeDeletion() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write(".codex/visualizations/2026/10/22/run/shot.png")
        let day = CleanupPath.fileURL(f.base.appending(path: ".codex/visualizations/2026/10/22"))
        let candidate = try #require(TemporaryBuildInspector.inspect(day, activity: .idle, now: f.later(hours: 30), home: f.base))
        #expect(candidate.risk == .medium && candidate.deletionMode == .item && candidate.category == .cache)
        try SafetyPolicy(home: f.base, now: f.later(hours: 30)).validate(candidate)
        try TemporaryBuildInspector.verifyBeforeDeletion(candidate, activity: .idle, now: f.later(hours: 30), home: f.base)
        // Too new: not offered.
        #expect(TemporaryBuildInspector.inspect(day, activity: .idle, now: f.later(hours: 2), home: f.base) == nil)
    }

    @Test func folderWithALockedFileIsNeverOffered() throws {
        let f = try TemporaryBuildFixture()
        let locked = try f.write(".codex/visualizations/2026/10/22/device/save.json")
        defer { _ = chflags(locked.path, 0); f.remove() }
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        let day = CleanupPath.fileURL(f.base.appending(path: ".codex/visualizations/2026/10/22"))
        #expect(TemporaryBuildInspector.inspect(day, activity: .idle, now: f.later(hours: 200), home: f.base) == nil)
    }

    @Test func swiftPackageFoldersAreFoundByLayoutAndMayHoldGitClones() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write("lane-sp/workspace-state.json")
        try f.write("lane-sp/repositories/pkg-1/HEAD")
        try f.write("lane-sp/checkouts/pkg/.git/HEAD")
        try f.write("lane-cache/manifests/m.json")
        try f.write("lane-cache/repositories/pkg-1/HEAD")
        try f.write("not-packages/repositories/x")
        let sp = CleanupPath.fileURL(f.base.appending(path: "lane-sp"))
        #expect(TemporaryBuildOutput.kind(of: sp, home: f.base) == .swiftPackages)
        #expect(TemporaryBuildOutput.kind(of: f.base.appending(path: "lane-cache"), home: f.base) == .swiftPackages)
        #expect(TemporaryBuildOutput.kind(of: f.base.appending(path: "not-packages"), home: f.base) == nil)
        let candidate = try #require(TemporaryBuildInspector.inspect(sp, activity: .idle, now: f.later(hours: 30), home: f.base))
        #expect(candidate.risk == .low)
        // Git data outside the clone folders can be someone's work.
        try f.write("lane-sp/notes/.git/HEAD")
        #expect(TemporaryBuildInspector.inspect(sp, activity: .idle, now: f.later(hours: 30), home: f.base) == nil)
    }

    @Test func codexTaskBundlesAreFoundButArchivesAreKept() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write("Documents/Codex/2026-11-08/yo/work/run.xcresult/Info.plist")
        try f.write("Documents/Codex/2026-11-08/yo/work/App.xcarchive/Products/Applications/App.app/Info.plist")
        try f.write("Documents/Codex/2026-11-08/yo/work/App.xcarchive/dSYMs/App.app.dSYM/Contents/Info.plist")
        let run = CleanupPath.fileURL(f.base.appending(path: "Documents/Codex/2026-11-08/yo/work/run.xcresult"))
        #expect(AgentWorkspaceDiscovery.taskBundles(home: f.base) == [run])
        #expect(TemporaryBuildOutput.kind(of: run, home: f.base) == .resultBundle)
        let archive = f.base.appending(path: "Documents/Codex/2026-11-08/yo/work/App.xcarchive")
        #expect(TemporaryBuildOutput.kind(of: archive, home: f.base) == nil)
    }

    @Test func topLevelSkipsClaudeProjectFolders() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let claude = try f.folder("claude-fixture")
        let lane = try f.folder("claude-fixture/lane-a-sp")
        _ = try f.folder("claude-fixture/-Users-someone-project")
        let other = try f.folder("other")
        #expect(Set(AgentWorkspaceDiscovery.topLevel(temporaryRoot: f.base, claudeRoot: claude)) == [other, lane])
    }

    @Test func discoveredSwiftPackageFolderIsOfferedWhole() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write("Documents/Codex/2026-11-08/yo/work/.build/workspace-state.json")
        try f.write("Documents/Codex/2026-11-08/yo/work/.build/repositories/pkg-1/HEAD")
        let build = CleanupPath.fileURL(f.base.appending(path: "Documents/Codex/2026-11-08/yo/work/.build"))
        let result = TemporaryBuildInspector.scan(discovered: [build], activity: .idle, now: f.later(hours: 30),
                                                  home: f.base, extraFolders: { [] })
        #expect(result.candidates.map(\.url) == [build])
        #expect(result.generatedRoots.isEmpty)
    }

    @Test func aFolderFoundTwiceIsOfferedOnce() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let derived = try f.derivedData("app-derived")
        let result = TemporaryBuildInspector.scan(discovered: [derived], activity: .idle, now: f.later(hours: 30),
                                                  home: f.base, extraFolders: { [derived] })
        #expect(result.candidates.map(\.url) == [derived])
    }
}
