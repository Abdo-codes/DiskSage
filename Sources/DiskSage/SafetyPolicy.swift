import Foundation
import Darwin

enum SafetyPolicyError: LocalizedError {
    case refused(String)

    var errorDescription: String? {
        switch self {
        case let .refused(reason): reason
        }
    }
}

struct SafetyPolicy: Sendable {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var now = Date()
    var keep = KeepRules.current()
    func validate(_ candidate: CleanupCandidate) throws {
        let home = CleanupPath.fileURL(self.home)
        let developer = home.appending(path: "Developer", directoryHint: .isDirectory)
        let url = CleanupPath.fileURL(candidate.url)
        let path = url.path
        guard !keep.keeps(url) else {
            throw SafetyPolicyError.refused("A keep rule in Settings protects this item.")
        }

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
        if candidate.deletionMode == .generatedFiles {
            guard let snapshot = candidate.generatedSnapshot,
                  snapshot.fileCount > 0, candidate.identity != FileIdentity(device: 0, inode: 0),
                  snapshot.cutoff.timeIntervalSince1970.isFinite,
                  snapshot.cutoff <= now.addingTimeInterval(-GeneratedCleanupPolicy.minimumAge + 1), snapshot.digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  GeneratedCleanupScope.rule(for: url, home: home) == snapshot.rule else {
                throw SafetyPolicyError.refused("The generated-file scope is invalid. Scan again.")
            }
            try rejectSymlinkedAncestors(of: url)
            try verifyIdentity(of: url, expected: candidate.identity)
            return
        }
        if candidate.deletionMode == .simulatorDevices {
            throw SafetyPolicyError.refused("DiskSage deletes simulators one device at a time. Scan again.")
        }
        if candidate.deletionMode == .simulatorDevice {
            // simctl removes the folder. SimulatorInventory checks the state and activity again before deletion.
            guard url.deletingLastPathComponent() == SimulatorInventory.devicesRoot(home: home),
                  SimulatorDevice.isUDID(url.lastPathComponent),
                  candidate.identity != FileIdentity(device: 0, inode: 0) else {
                throw SafetyPolicyError.refused("A simulator candidate must be one device folder.")
            }
            try rejectSymlinkedAncestors(of: url)
            try verifyIdentity(of: url, expected: candidate.identity)
            return
        }
        if TemporaryBuildOutput.kind(of: url, home: home) != nil {
            // Whole temporary build folders. Git data, age, sessions and activity are checked by
            // TemporaryBuildInspector when the candidate is made and again right before deletion.
            guard candidate.deletionMode == .item else {
                throw SafetyPolicyError.refused("Temporary build output is deleted only as a whole folder.")
            }
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                throw SafetyPolicyError.refused("Symlinked targets are not allowed.")
            }
            try rejectSymlinkedAncestors(of: url)
            try verifyIdentity(of: url, expected: candidate.identity)
            return
        }
        let exactTargets = [
            home.appending(path: "Library/Developer/Xcode/DerivedData", directoryHint: .isDirectory),
            home.appending(path: "Library/Developer/Xcode/Archives", directoryHint: .isDirectory),
            home.appending(path: "Library/Developer/CoreSimulator/Devices", directoryHint: .isDirectory),
            home.appending(path: ".npm/_cacache", directoryHint: .isDirectory),
            URL(fileURLWithPath: "/private/var/tmp/_bazel_\(NSUserName())", isDirectory: true)
        ].map(\.standardizedFileURL)


        let cacheRoots = [
            home.appending(path: "Library/Caches", directoryHint: .isDirectory),
            home.appending(path: ".cache", directoryHint: .isDirectory)
        ].map(\.standardizedFileURL)

        let buildNames = Set([".build", "build", "DerivedData", "derived-data"])
        guard exactTargets.contains(url) || cacheRoots.contains(where: { url.deletingLastPathComponent() == $0 }) ||
              path.hasPrefix(developer.path + "/") && buildNames.contains(url.lastPathComponent) else {
            throw SafetyPolicyError.refused("The path is outside DiskSage’s cleanup allowlist.")
        }
        // Authorize scope before enumerating any contents (including cloud-backed folders).
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw SafetyPolicyError.refused("Symlinked targets are not allowed.")
        }
        try rejectSymlinkedAncestors(of: url)
        try verifyIdentity(of: url, expected: candidate.identity)
        do { try WorktreePathGuard.rejectSourceContainers(url) }
        catch { throw SafetyPolicyError.refused(error.localizedDescription) }
    }

    private func rejectSymlinkedAncestors(of url: URL) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            current.append(path: component)
            var info = stat()
            guard lstat(current.path, &info) == 0 else {
                if errno == ENOENT { return }
                throw SafetyPolicyError.refused("Unable to verify \(current.path).")
            }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                throw SafetyPolicyError.refused("A symlinked path component is not allowed: \(current.path)")
            }
        }
    }

    private func verifyIdentity(of url: URL, expected: FileIdentity) throws {
        guard expected.device != 0 || expected.inode != 0 else { return }
        var info = stat()
        guard lstat(url.path, &info) == 0,
              UInt64(info.st_dev) == expected.device,
              UInt64(info.st_ino) == expected.inode else {
            throw SafetyPolicyError.refused("The item changed after it was scanned. Scan again before deleting it.")
        }
    }
}
