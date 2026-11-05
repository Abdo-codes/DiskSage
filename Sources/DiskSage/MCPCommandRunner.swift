import Darwin
import Foundation

struct MCPCommandOutput: Sendable {
    let exitCode: Int32
    let text: String
}

enum MCPCommandRunner {
    static func run(executable: URL, arguments: [String], timeout: TimeInterval = 15,
                    environment: [String: String] = ProcessInfo.processInfo.environment) throws -> MCPCommandOutput {
        var info = stat()
        guard lstat(executable.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & S_IWOTH) == 0, info.st_uid == 0 || info.st_uid == getuid() else {
            throw FeatureFailure(message: "The client executable has unsafe ownership or permissions. Check its installation.")
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "DiskSage-MCP-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "output")
        _ = FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Avoid project-specific configuration and hooks in the repository hosting DiskSage.
        process.currentDirectoryURL = directory
        let keys = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "CODEX_HOME", "CLAUDE_CONFIG_DIR"]
        process.environment = Dictionary(uniqueKeysWithValues: keys.compactMap { key in environment[key].map { (key, $0) } })
        process.environment?["PATH"] = (environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        if completed.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 2)
            }
            throw FeatureFailure(message: "The client took too long to respond. Check its installation or use Manual setup.")
        }
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 512_000 else {
            throw FeatureFailure(message: "The client returned too much output. Use Manual setup to inspect it.")
        }
        return MCPCommandOutput(exitCode: process.terminationStatus, text: String(decoding: try Data(contentsOf: file), as: UTF8.self))
    }
}
