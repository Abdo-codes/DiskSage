import Darwin
import Foundation

/// Offers tool caches that the tools clean themselves, and runs the tool's command to clean one.
enum ToolCacheInventory {
    typealias Run = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String])
        throws -> (code: Int32, data: Data)
    typealias Trusted = @Sendable (String) -> Bool

    /// Smaller caches are not worth a command.
    static let minimumBytes: Int64 = 100 * 1_048_576
    /// A tool that waits longer than this for a lock is stopped; the cache is in use.
    static let timeout: TimeInterval = 300
    private static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    static let process: Run = { executable, arguments, environment in
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let output = try WorktreeGitProcess().execute(executable, arguments, timeout: timeout,
                                                          environment: environment, workingDirectory: home)
            return (output.code, output.data)
        } catch let error as FeatureFailure {
            throw FeatureFailure(message: "\(error.message) The cache can be in use. Try again later.")
        }
    }

    /// The executable must resolve to a regular executable file that the current user or root owns
    /// and that nobody else can change.
    static let isTrusted: Trusted = { path in
        guard let resolved = realpath(path, nil) else { return false }
        defer { free(resolved) }
        var info = stat()
        guard stat(resolved, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o111 != 0 && info.st_mode & 0o022 == 0 &&
            (info.st_uid == getuid() || info.st_uid == 0)
    }

    /// Builds the process environment for `tool`, adding only explicitly trusted Node binary directories
    /// to `PATH` when `tool.needsNodeRuntime` is true (for `#!/usr/bin/env node` shims like Corepack).
    static func executionEnvironment(for tool: ToolCache, executable: String, home: URL,
                                     trusted: Trusted = isTrusted) -> [String: String] {
        var env = tool.environment
        guard tool.needsNodeRuntime else { return env }
        let nodeDirs = ToolCache.trustedNodeCandidates(home: home, executable: executable)
            .filter(trusted)
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        guard !nodeDirs.isEmpty else { return env }
        var seen = Set<String>()
        let unique = nodeDirs.filter { seen.insert($0).inserted }
        env["PATH"] = (unique + [systemPath]).joined(separator: ":")
        return env
    }

    static func candidates(activity: CleanupActivity, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           trusted: Trusted = isTrusted, run: Run = process,
                           size: (URL) -> Int64? = DiskScanner.allocatedSize) -> [CleanupCandidate] {
        ToolCache.all(home: home).compactMap { tool in
            guard !Task.isCancelled, let executable = tool.executables.first(where: trusted),
                  TemporaryBuildOutput.isRealDirectory(tool.folder), !activity.contains(tool.folder),
                  let identity = identity(of: tool.folder) else { return nil }
            let env = executionEnvironment(for: tool, executable: executable, home: home, trusted: trusted)
            guard preflightFailure(for: tool, executable: executable, environment: env, run: run) == nil,
                  let bytes = estimate(tool, executable: executable, environment: env, run: run, size: size),
                  bytes >= minimumBytes else { return nil }
            return CleanupCandidate(url: tool.folder, name: tool.name, category: .cache, size: bytes, risk: .low,
                                    reason: tool.reason, identity: identity, deletionMode: .toolCommand)
        }
    }

    /// Runs right before cleaning: the folder must still be a known tool cache that passes its checks and is idle.
    /// Measures the cache folder before and after so partial-pruning commands report actual reclaimed bytes.
    @discardableResult
    static func clean(_ candidate: CleanupCandidate, activity: CleanupActivity,
                      home: URL = FileManager.default.homeDirectoryForCurrentUser,
                      trusted: Trusted = isTrusted, run: Run = process,
                      size: (URL) -> Int64? = DiskScanner.allocatedSize) throws -> CleanupRemoval? {
        guard let tool = ToolCache.matching(candidate.url, home: home) else {
            throw SafetyPolicyError.refused("The folder is not a known tool cache.")
        }
        guard let executable = tool.executables.first(where: trusted) else {
            throw FeatureFailure(message: "\(tool.name): the tool is no longer installed. Nothing was deleted.")
        }
        try activity.requireIdle(candidate.url)
        let env = executionEnvironment(for: tool, executable: executable, home: home, trusted: trusted)
        if let refusal = preflightFailure(for: tool, executable: executable, environment: env, run: run) {
            throw FeatureFailure(message: "\(tool.name): \(refusal) Nothing was deleted.")
        }
        let before = size(candidate.url)
        let code = try run(executable, tool.arguments, env).code
        guard code == 0 else { throw FeatureFailure(message: "\(tool.name): the cleanup command stopped with code \(code).") }
        if let before {
            let after = size(candidate.url) ?? 0
            return CleanupRemoval(removedBytes: max(0, before - after), skippedFiles: 0)
        }
        return nil
    }

    private static func preflightFailure(for tool: ToolCache, executable: String,
                                         environment: [String: String], run: Run) -> String? {
        for check in tool.preflightChecks {
            guard let output = try? run(executable, check.arguments, environment) else {
                return check.refusalReason
            }
            if let failure = check.evaluate(code: output.code, text: String(decoding: output.data, as: UTF8.self)) {
                return failure
            }
        }
        return nil
    }

    /// What the command will free: the tool's own dry run when it has one, else the folder size.
    private static func estimate(_ tool: ToolCache, executable: String, environment: [String: String],
                                 run: Run, size: (URL) -> Int64?) -> Int64? {
        guard let arguments = tool.estimateArguments else { return size(tool.folder) }
        guard let output = try? run(executable, arguments, environment), output.code == 0 else { return nil }
        return ToolCache.freedBytes(fromDryRun: String(decoding: output.data, as: UTF8.self))
    }

    private static func identity(of url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}
