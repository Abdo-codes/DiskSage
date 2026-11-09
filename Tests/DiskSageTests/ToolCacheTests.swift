import Darwin
import Foundation
import Testing
@testable import DiskSage

/// Records every command and answers with a fixed exit code. Nothing runs.
private final class FakeTool: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(String, [String], [String: String])] = []
    let code: Int32
    init(code: Int32 = 0) { self.code = code }
    var run: ToolCacheInventory.Run {
        { [self] executable, arguments, environment in
            lock.withLock { calls.append((executable, arguments, environment)) }
            return code
        }
    }
}

/// The fixture folder stands in for the home folder.
struct ToolCacheTests {
    let big: (URL) -> Int64? = { _ in 200 * 1_048_576 }
    let onlyBrew: ToolCacheInventory.Trusted = { $0 == "/opt/homebrew/bin/brew" }

    @Test func offersInstalledToolCachesThatAreLargeAndIdle() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write("Library/Caches/Homebrew/downloads/a.tar.gz")
        try f.write(".cache/uv/wheels-v5/a.whl")
        let brew = CleanupPath.fileURL(f.base.appending(path: "Library/Caches/Homebrew"))
        // uv is not installed: only the Homebrew cache is offered.
        let found = ToolCacheInventory.candidates(activity: .idle, home: f.base, trusted: onlyBrew, size: big)
        #expect(found.map(\.url) == [brew])
        #expect(found.allSatisfy { $0.risk == .low && $0.deletionMode == .toolCommand && $0.category == .cache })
        try SafetyPolicy(home: f.base).validate(try #require(found.first))
        // Small caches and caches in use are not offered.
        #expect(ToolCacheInventory.candidates(activity: .idle, home: f.base, trusted: onlyBrew, size: { _ in 4_096 }).isEmpty)
        let busy = CleanupActivity(paths: [brew.path + "/downloads/a.tar.gz"])
        #expect(ToolCacheInventory.candidates(activity: busy, home: f.base, trusted: onlyBrew, size: big).isEmpty)
    }

    @Test func cleanRunsOnlyTheToolsOwnCommand() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write(".cache/uv/wheels-v5/a.whl")
        let uv = CleanupPath.fileURL(f.base.appending(path: ".cache/uv"))
        let trusted: ToolCacheInventory.Trusted = { $0 == "/opt/homebrew/bin/uv" }
        let candidate = try #require(ToolCacheInventory.candidates(activity: .idle, home: f.base, trusted: trusted, size: big).first)
        let tool = FakeTool()
        try ToolCacheInventory.clean(candidate, activity: .idle, home: f.base, trusted: trusted, run: tool.run)
        #expect(tool.calls.count == 1)
        #expect(tool.calls.first?.0 == "/opt/homebrew/bin/uv")
        #expect(tool.calls.first?.1 == ["cache", "clean", "--cache-dir", uv.path])
        // A process starts to use the cache: the command does not run.
        let busy = CleanupActivity(paths: [uv.path + "/wheels-v5/a.whl"])
        #expect(throws: (any Error).self) {
            try ToolCacheInventory.clean(candidate, activity: busy, home: f.base, trusted: trusted, run: tool.run)
        }
        // A failed command is reported.
        #expect(throws: (any Error).self) {
            try ToolCacheInventory.clean(candidate, activity: .idle, home: f.base, trusted: trusted, run: FakeTool(code: 1).run)
        }
        #expect(tool.calls.count == 1)
    }

    @Test func otherFoldersAreRefused() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let other = try f.folder(".cache/pip")
        var info = stat(); _ = lstat(other.path, &info)
        let candidate = CleanupCandidate(url: other, name: "x", category: .cache, size: 1, risk: .low, reason: "",
            identity: FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)), deletionMode: .toolCommand)
        #expect(throws: (any Error).self) { try SafetyPolicy(home: f.base).validate(candidate) }
        let tool = FakeTool()
        #expect(throws: (any Error).self) {
            try ToolCacheInventory.clean(candidate, activity: .idle, home: f.base, trusted: { _ in true }, run: tool.run)
        }
        #expect(tool.calls.isEmpty)
    }

    @Test func onlyProtectedExecutablesAreTrusted() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        #expect(ToolCacheInventory.isTrusted("/bin/ls"))
        let open = try f.write("bin/tool")
        #expect(chmod(open.path, 0o777) == 0)
        #expect(!ToolCacheInventory.isTrusted(open.path))
        #expect(chmod(open.path, 0o755) == 0)
        #expect(ToolCacheInventory.isTrusted(open.path))
        #expect(!ToolCacheInventory.isTrusted(f.base.appending(path: "bin/missing").path))
    }
}
