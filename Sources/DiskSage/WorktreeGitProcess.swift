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
    func execute(_ executable: String, _ args: [String], allowTermination: Bool = true,
                 timeout: TimeInterval = 20, environment: [String: String] = [:]) throws -> Output {
        let directory = FileManager.default.temporaryDirectory.appending(path: "disksage-git-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "output")
        _ = FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_LAZY_FETCH": "1",
            "GIT_NO_REPLACE_OBJECTS": "1", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
            .merging(environment) { _, added in added }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if allowTermination && (Task.isCancelled || Date() > deadline || size > 8_000_000) {
                process.terminate()
                usleep(100_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw FeatureFailure(message: "\(URL(fileURLWithPath: executable).lastPathComponent) was cancelled or exceeded its time/output limit.")
            }
            usleep(10_000)
        }
        process.waitUntilExit()
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        return Output(data: try reader.read(upToCount: 8_000_000) ?? Data(), code: process.terminationStatus)
    }
}
