import Foundation

enum SafetyPolicyError: LocalizedError {
    case refused(String)

    var errorDescription: String? {
        switch self {
        case let .refused(reason): reason
        }
    }
}

struct SafetyPolicy: Sendable {
    func validate(_ candidate: CleanupCandidate) throws {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        let developer = home.appending(path: "Developer", directoryHint: .isDirectory)
        let url = candidate.url.standardizedFileURL
        let path = url.path

        guard path != "/", url != home, url != developer else {
            throw SafetyPolicyError.refused("DiskSage refuses broad root directories.")
        }
        guard !url.pathComponents.contains(".git") else {
            throw SafetyPolicyError.refused("Git data is never a cleanup target.")
        }
        if let executable = Bundle.main.executableURL?.standardizedFileURL,
           executable.path.hasPrefix(url.path + "/") {
            throw SafetyPolicyError.refused("DiskSage cannot delete the directory containing its running executable.")
        }
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw SafetyPolicyError.refused("Symlinked targets are not allowed.")
        }

        let exactTargets = [
            home.appending(path: "Library/Developer/Xcode/DerivedData", directoryHint: .isDirectory),
            home.appending(path: "Library/Developer/Xcode/Archives", directoryHint: .isDirectory),
            home.appending(path: "Library/Developer/CoreSimulator/Devices", directoryHint: .isDirectory),
            home.appending(path: ".npm/_cacache", directoryHint: .isDirectory),
            URL(fileURLWithPath: "/private/var/tmp/_bazel_\(NSUserName())", isDirectory: true)
        ].map(\.standardizedFileURL)

        if exactTargets.contains(url) { return }

        let cacheRoots = [
            home.appending(path: "Library/Caches", directoryHint: .isDirectory),
            home.appending(path: ".cache", directoryHint: .isDirectory)
        ].map(\.standardizedFileURL)
        if cacheRoots.contains(where: { url.deletingLastPathComponent() == $0 }) { return }

        let buildNames = Set([".build", "build", "DerivedData", "derived-data"])
        if path.hasPrefix(developer.path + "/"), buildNames.contains(url.lastPathComponent) { return }

        throw SafetyPolicyError.refused("The path is outside DiskSage’s cleanup allowlist.")
    }
}

struct CleanupService: Sendable {
    let policy = SafetyPolicy()

    func delete(_ candidates: [CleanupCandidate]) async throws -> Int64 {
        try await Task.detached(priority: .utility) {
            var removed: Int64 = 0
            for candidate in candidates {
                try policy.validate(candidate)
                guard FileManager.default.fileExists(atPath: candidate.url.path) else { continue }
                try FileManager.default.removeItem(at: candidate.url)
                removed += candidate.size
            }
            return removed
        }.value
    }
}
