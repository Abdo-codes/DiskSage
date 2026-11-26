import Darwin
import Foundation
import Testing
@testable import DiskSage

/// Records every command and answers with a fixed exit code. Nothing runs.
private final class FakeTool: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(String, [String], [String: String])] = []
    let code: Int32
    let dryRun: String
    init(code: Int32 = 0, dryRun: String = "==> This operation would free approximately 1.5GB of disk space.") {
        self.code = code; self.dryRun = dryRun
    }
    var run: ToolCacheInventory.Run {
        { [self] executable, arguments, environment in
            lock.withLock { calls.append((executable, arguments, environment)) }
            return (code, Data((arguments.contains("--dry-run") ? dryRun : "").utf8))
        }
    }
    var commands: [[String]] { lock.withLock { calls.map(\.1).filter { !$0.contains("--dry-run") } } }
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
        let found = ToolCacheInventory.candidates(activity: .idle, home: f.base, trusted: onlyBrew, run: FakeTool().run, size: big)
        #expect(found.map(\.url) == [brew])
        // The estimate comes from Homebrew's own dry run, not from the folder size.
        #expect(found.first?.size == 1_500_000_000)
        // The cleanup must never uninstall packages.
        #expect(ToolCache.all(home: f.base).first?.environment["HOMEBREW_NO_AUTOREMOVE"] == "1")
        let nothing = FakeTool(dryRun: "")
        #expect(ToolCacheInventory.candidates(activity: .idle, home: f.base, trusted: onlyBrew, run: nothing.run, size: big).isEmpty)
        #expect(nothing.commands.isEmpty)
        #expect(found.allSatisfy { $0.risk == .low && $0.deletionMode == .toolCommand && $0.category == .cache })
        try SafetyPolicy(home: f.base).validate(try #require(found.first))
        // Small caches and caches in use are not offered.
        #expect(ToolCacheInventory.candidates(activity: .idle, home: f.base, trusted: onlyBrew,
            run: FakeTool(dryRun: "would free approximately 12KB of disk space").run, size: big).isEmpty)
        let busy = CleanupActivity(paths: [brew.path + "/downloads/a.tar.gz"])
        #expect(ToolCacheInventory.candidates(activity: busy, home: f.base, trusted: onlyBrew, run: FakeTool().run, size: big).isEmpty)
    }

    @Test func cleanRunsOnlyTheToolsOwnCommand() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write(".cache/uv/wheels-v5/a.whl")
        let uv = CleanupPath.fileURL(f.base.appending(path: ".cache/uv"))
        let trusted: ToolCacheInventory.Trusted = { $0 == "/opt/homebrew/bin/uv" }
        let candidate = try #require(ToolCacheInventory.candidates(activity: .idle, home: f.base, trusted: trusted,
                                                                   run: FakeTool().run, size: big).first)
        #expect(candidate.size == 200 * 1_048_576)
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

    @Test func readsTheHomebrewDryRunSummary() {
        #expect(ToolCache.freedBytes(fromDryRun: "Would remove: /x (1MB)\n==> This operation would free approximately 2.3GB of disk space.") == 2_300_000_000)
        #expect(ToolCache.freedBytes(fromDryRun: "would free approximately 512B of disk space") == 512)
        #expect(ToolCache.freedBytes(fromDryRun: "") == 0)
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

    @Test func offersAndCleansMisePnpmAndPipCaches() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write("Library/Caches/mise/node/archive.tar.xz")
        try f.write("Library/pnpm/store/v3/files/00/abc")
        try f.write("Library/Caches/pip/http-v2/a.whl")
        let miseDir = CleanupPath.fileURL(f.base.appending(path: "Library/Caches/mise"))
        let pnpmDir = CleanupPath.fileURL(f.base.appending(path: "Library/pnpm/store"))
        let pipDir = CleanupPath.fileURL(f.base.appending(path: "Library/Caches/pip"))
        let allowed: Set<String> = ["/opt/homebrew/bin/mise", "/opt/homebrew/bin/pnpm", "/opt/homebrew/bin/pip3", "/opt/homebrew/bin/node"]
        let trusted: ToolCacheInventory.Trusted = { allowed.contains($0) }
        let miseDryRun = FakeTool(dryRun: "mise pruning /tmp/old.tar\nmise cache pruned 2 files, 150.0 MiB\n")

        let found = ToolCacheInventory.candidates(activity: .idle, home: f.base, trusted: trusted, run: miseDryRun.run, size: big)
        #expect(Set(found.map(\.url)) == Set([miseDir, pnpmDir, pipDir]))
        let miseCandidate = try #require(found.first { $0.url == miseDir })
        #expect(miseCandidate.size == 150 * 1_048_576)
        for candidate in found {
            try SafetyPolicy(home: f.base).validate(candidate)
        }

        // When mise --dry-run reports 0 B prunable, mise is not offered even if the cache directory is large.
        let miseNothing = FakeTool(dryRun: "mise cache pruned 0 files, 0 B\n")
        let withoutMise = ToolCacheInventory.candidates(activity: .idle, home: f.base, trusted: trusted, run: miseNothing.run, size: big)
        #expect(!withoutMise.contains(where: { $0.url == miseDir }))

        let tool = FakeTool()
        for candidate in found {
            try ToolCacheInventory.clean(candidate, activity: .idle, home: f.base, trusted: trusted, run: tool.run)
        }
        #expect(tool.calls.contains { $0.0 == "/opt/homebrew/bin/mise" && $0.1 == ["cache", "prune"] && $0.2["MISE_CACHE_DIR"] == miseDir.path })
        #expect(tool.calls.contains {
            $0.0 == "/opt/homebrew/bin/pnpm" && $0.1 == ["store", "prune"] &&
                $0.2["npm_config_store_dir"] == pnpmDir.path &&
                $0.2["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        })
        #expect(tool.calls.contains { $0.0 == "/opt/homebrew/bin/pip3" && $0.1 == ["cache", "purge"] && $0.2["PIP_CACHE_DIR"] == pipDir.path && $0.2["PATH"] == nil })
    }

    @Test func measuresActualBytesRemovedByPartialPruneAndReadsMiseDryRun() throws {
        #expect(ToolCache.freedBytes(fromDryRun: "mise cache pruned 1 files, 2.0 MiB\n") == 2 * 1_048_576)
        #expect(ToolCache.freedBytes(fromDryRun: "mise cache pruned 0 files, 0 B\n") == 0)
        #expect(ToolCache.freedBytes(fromDryRun: "mise cache pruned 4 files, 1.5 GiB\n") == Int64(1.5 * 1_073_741_824))

        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write("Library/Caches/mise/old.tar")
        let miseDir = CleanupPath.fileURL(f.base.appending(path: "Library/Caches/mise"))
        let trusted: ToolCacheInventory.Trusted = { $0 == "/opt/homebrew/bin/mise" }
        let dryRun = FakeTool(dryRun: "mise cache pruned 2 files, 200.0 MiB\n")
        let candidate = try #require(ToolCacheInventory.candidates(activity: .idle, home: f.base, trusted: trusted,
                                                                   run: dryRun.run, size: big).first)
        #expect(candidate.url == miseDir)

        // Simulate a partial prune: folder drops from 200 MiB to 160 MiB -> reports 40 MiB actually removed.
        var reads = [200 * 1_048_576, 160 * 1_048_576] as [Int64]
        let removal = try ToolCacheInventory.clean(candidate, activity: .idle, home: f.base, trusted: trusted,
                                                   run: FakeTool().run, size: { _ in reads.removeFirst() })
        #expect(removal == CleanupRemoval(removedBytes: 40 * 1_048_576, skippedFiles: 0))

        // Simulate a no-op prune: folder unchanged -> reports 0 removed bytes.
        let noop = try ToolCacheInventory.clean(candidate, activity: .idle, home: f.base, trusted: trusted,
                                                run: FakeTool().run, size: { _ in 160 * 1_048_576 })
        #expect(noop == CleanupRemoval(removedBytes: 0, skippedFiles: 0))
    }

    @Test func nodeRuntimePathIsIncludedForNodeShimsAndOmittedWhenUntrusted() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let yarn = try #require(ToolCache.all(home: f.base).first { $0.name == "Yarn 1 package cache" })
        let trustedNode: ToolCacheInventory.Trusted = { $0 == "/opt/homebrew/bin/node" }
        let envWithNode = ToolCacheInventory.executionEnvironment(for: yarn, executable: "/opt/homebrew/bin/yarn",
                                                                  home: f.base, trusted: trustedNode)
        #expect(envWithNode["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")

        let noNode: ToolCacheInventory.Trusted = { _ in false }
        let envWithoutNode = ToolCacheInventory.executionEnvironment(for: yarn, executable: "/opt/homebrew/bin/yarn",
                                                                     home: f.base, trusted: noNode)
        #expect(envWithoutNode["PATH"] == nil)
    }

    @Test func bunRequiresVersionAtLeast144() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write(".bun/install/cache/pkg/index.js")
        let bunDir = CleanupPath.fileURL(f.base.appending(path: ".bun/install/cache"))
        let trusted: ToolCacheInventory.Trusted = { $0 == "/opt/homebrew/bin/bun" }
        func runner(version: String) -> ToolCacheInventory.Run {
            { _, arguments, _ in
                if arguments == ["--version"] { return (0, Data("\(version)\n".utf8)) }
                return (0, Data())
            }
        }

        #expect(ToolCacheInventory.candidates(activity: .idle, home: f.base, trusted: trusted, run: runner(version: "1.4.3"), size: big).isEmpty)
        #expect(ToolCacheInventory.candidates(activity: .idle, home: f.base, trusted: trusted, run: runner(version: "1.2.0"), size: big).isEmpty)
        let offered = try #require(ToolCacheInventory.candidates(activity: .idle, home: f.base, trusted: trusted, run: runner(version: "1.4.4"), size: big).first)
        #expect(offered.url == bunDir)
        try ToolCacheInventory.clean(offered, activity: .idle, home: f.base, trusted: trusted, run: runner(version: "1.5.0"))
        // If Bun was downgraded before clean runs, preflight stops cleanup.
        #expect(throws: (any Error).self) {
            try ToolCacheInventory.clean(offered, activity: .idle, home: f.base, trusted: trusted, run: runner(version: "1.4.3"))
        }
    }

    @Test func yarnRefusesYarn2AndLater() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write("Library/Caches/Yarn/v6/pkg.tgz")
        let yarnDir = CleanupPath.fileURL(f.base.appending(path: "Library/Caches/Yarn"))
        let trusted: ToolCacheInventory.Trusted = { $0 == "/opt/homebrew/bin/yarn" }
        func runner(version: String) -> ToolCacheInventory.Run {
            { _, arguments, _ in
                if arguments == ["--version"] { return (0, Data("\(version)\n".utf8)) }
                return (0, Data())
            }
        }

        #expect(ToolCacheInventory.candidates(activity: .idle, home: f.base, trusted: trusted, run: runner(version: "4.5.0"), size: big).isEmpty)
        #expect(ToolCacheInventory.candidates(activity: .idle, home: f.base, trusted: trusted, run: runner(version: "2.4.3"), size: big).isEmpty)
        let offered = try #require(ToolCacheInventory.candidates(activity: .idle, home: f.base, trusted: trusted, run: runner(version: "1.22.22"), size: big).first)
        #expect(offered.url == yarnDir)
        try ToolCacheInventory.clean(offered, activity: .idle, home: f.base, trusted: trusted, run: runner(version: "1.22.22"))
        // Switching to Yarn Berry before cleanup stops deletion.
        #expect(throws: (any Error).self) {
            try ToolCacheInventory.clean(offered, activity: .idle, home: f.base, trusted: trusted, run: runner(version: "4.5.0"))
        }
    }

    @Test func trustedNodeCandidatesFindsMiseNvmDescendingAndFnmAndMiseShims() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write(".nvm/versions/node/v9.0.0/bin/node")
        try f.write(".nvm/versions/node/v24.2.0/bin/node")
        try f.write(".local/share/mise/installs/node/22.22.0/bin/node")
        let nvm24 = CleanupPath.fileURL(f.base.appending(path: ".nvm/versions/node/v24.2.0/bin/node")).path
        let nvm9 = CleanupPath.fileURL(f.base.appending(path: ".nvm/versions/node/v9.0.0/bin/node")).path
        let miseShimNode = CleanupPath.fileURL(f.base.appending(path: ".local/share/mise/shims/node")).path
        let fnmDefaultNode = CleanupPath.fileURL(f.base.appending(path: ".local/share/fnm/aliases/default/bin/node")).path

        let pnpm = try #require(ToolCache.all(home: f.base).first { $0.name == "pnpm package store" })
        #expect(pnpm.executables.contains(CleanupPath.fileURL(f.base.appending(path: ".local/share/mise/shims/pnpm")).path))

        let candidates = ToolCache.trustedNodeCandidates(home: f.base, executable: "/custom/bin/pnpm")
        let index24 = try #require(candidates.firstIndex(of: nvm24))
        let index9 = try #require(candidates.firstIndex(of: nvm9))
        #expect(index24 < index9)
        #expect(candidates.contains(miseShimNode))
        #expect(candidates.contains(fnmDefaultNode))

        // Only a trusted fnm Node binary gets added to PATH.
        let trustedFnm: ToolCacheInventory.Trusted = { $0 == fnmDefaultNode }
        let env = ToolCacheInventory.executionEnvironment(for: pnpm, executable: "/custom/bin/pnpm",
                                                          home: f.base, trusted: trustedFnm)
        let fnmBinDir = URL(fileURLWithPath: fnmDefaultNode).deletingLastPathComponent().path
        #expect(env["PATH"] == "\(fnmBinDir):/usr/bin:/bin:/usr/sbin:/sbin")
    }
}
