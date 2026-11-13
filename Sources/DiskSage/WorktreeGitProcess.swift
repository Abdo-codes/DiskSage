import Foundation

/// No shell, inherited Git state, credential prompts, lazy fetch or executable repository helpers.
struct WorktreeGitProcess: Sendable {
    struct Output { var data: Data; var code: Int32; var text: String { String(decoding: data, as: UTF8.self) } }
    func run(_ path: String, _ arguments: [String], allowed: Set<Int32> = [0]) throws -> Output {
        let output = try execute("/usr/bin/git", ["--no-pager", "--no-optional-locks", "-c", "core.fsmonitor=false",
            "-c", "core.untrackedCache=false", "-c", "core.attributesFile=/dev/null",
            "-c", "diff.external=", "-C", path] + arguments,
            allowTermination: !arguments.starts(with: ["worktree", "remove"]))
        guard allowed.contains(output.code) else {
            throw FeatureFailure(message: "Git refused \(arguments.first ?? "inspection"): \(output.text.prefix(700))")
        }
        return output
    }
    func text(_ path: String, _ args: [String], allowed: Set<Int32> = [0]) throws -> String {
        try run(path, args, allowed: allowed).text.trimmingCharacters(in: .newlines)
    }
    func rejectHelpers(_ path: String) throws {
        try WorktreeGitConfiguration.validate(self, path: path)
    }
    func indexBlockers(_ path: String) throws -> [String] {
        let entries = try run(path, ["ls-files", "-v", "--stage", "-z"]).text.split(separator: "\0")
        var blockers: [String] = []
        if entries.contains(where: { $0.first?.isLowercase == true || $0.first == "S" }) {
            blockers.append("Index has assume-unchanged or skip-worktree entries.")
        }
        if entries.contains(where: { $0.dropFirst(2).hasPrefix("160000 ") }) {
            blockers.append("Submodules are unsupported.")
        }
        return blockers
    }
    /// `environment` adds to the fixed environment. A run that is still going after `timeout` seconds is stopped.
    /// The output stays in memory, so a full disk cannot break a check. `outputLimit` is the largest accepted output.
    func execute(_ executable: String, _ args: [String], allowTermination: Bool = true, timeout: TimeInterval = 20,
                 environment: [String: String] = [:], outputLimit: Int = 8_000_000) throws -> Output {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_LAZY_FETCH": "1",
            "GIT_NO_REPLACE_OBJECTS": "1", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
            .merging(environment) { _, added in added }
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        try? pipe.fileHandleForWriting.close()
        let buffer = ProcessOutputBuffer()
        let reader = pipe.fileHandleForReading
        // Close the read end on each path. Without this, each run kept one descriptor open until the app had none left.
        defer { try? reader.close() }
        // Its own thread: a blocked read must not hold a thread of the shared dispatch pool.
        Thread.detachNewThread {
            while let chunk = try? reader.read(upToCount: 65_536), !chunk.isEmpty { buffer.append(chunk) }
            buffer.finish()
        }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            let tooLarge = buffer.count > outputLimit
            if allowTermination && (Task.isCancelled || Date() > deadline || tooLarge) {
                process.terminate()
                usleep(100_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw FeatureFailure(message: tooLarge ? "\(name) exceeded its output limit."
                    : "\(name) was cancelled or exceeded its time limit.")
            }
            usleep(10_000)
        }
        process.waitUntilExit()
        // A child that keeps the pipe open must not block the result.
        let complete = buffer.wait(seconds: 2)
        guard complete, buffer.count <= outputLimit else { throw FeatureFailure(message: "\(name) exceeded its output limit.") }
        return Output(data: buffer.data, code: process.terminationStatus)
    }
}
