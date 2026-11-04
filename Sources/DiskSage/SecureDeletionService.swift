import Darwin
import Foundation

enum SecureDeletionError: LocalizedError {
    case systemCall(String, Int32)
    case identityChanged
    case crossedFilesystem(String)
    case simulatorCommandFailed(Int32)

    var errorDescription: String? {
        switch self {
        case let .systemCall(operation, code):
            "\(operation) failed: \(String(cString: strerror(code)))"
        case .identityChanged:
            "The item changed after scanning. Scan again before deleting it."
        case let .crossedFilesystem(path):
            "Refused to cross into another mounted filesystem at \(path)."
        case let .simulatorCommandFailed(status):
            "simctl failed with status \(status)."
        }
    }
}

struct CleanupService: Sendable {
    private let policy = SafetyPolicy()

    func delete(_ candidates: [CleanupCandidate]) async -> CleanupReport {
        await Task.detached(priority: .utility) {
            let before = Self.currentFreeSpace()
            var results: [CleanupItemResult] = []

            for candidate in candidates {
                do {
                    try policy.validate(candidate)
                    if candidate.deletionMode == .simulatorDevices {
                        try deleteSimulatorDevices()
                    } else {
                        try SecureFileDeleter.delete(candidate)
                    }
                    results.append(CleanupItemResult(
                        candidate: candidate,
                        removedBytes: candidate.size,
                        errorDescription: nil
                    ))
                } catch {
                    results.append(CleanupItemResult(
                        candidate: candidate,
                        removedBytes: 0,
                        errorDescription: error.localizedDescription
                    ))
                }
            }

            return CleanupReport(
                items: results,
                freeSpaceBefore: before,
                freeSpaceAfter: Self.currentFreeSpace()
            )
        }.value
    }

    private func deleteSimulatorDevices() throws {
        for arguments in [["simctl", "shutdown", "all"], ["simctl", "delete", "all"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 && arguments[1] == "delete" {
                throw SecureDeletionError.simulatorCommandFailed(process.terminationStatus)
            }
        }
    }

    private static func currentFreeSpace() -> Int64 {
        let values = try? URL(fileURLWithPath: "/System/Volumes/Data")
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

private enum SecureFileDeleter {
    static func delete(_ candidate: CleanupCandidate) throws {
        let components = candidate.url.standardizedFileURL.pathComponents
        guard components.count > 1, let targetName = components.last else {
            throw SafetyPolicyError.refused("Refused an unsafe root path.")
        }

        let parentFD = try openDirectoryChain(Array(components.dropFirst().dropLast()))
        defer { close(parentFD) }

        var targetInfo = stat()
        guard fstatat(parentFD, targetName, &targetInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw SecureDeletionError.systemCall("Inspecting \(candidate.url.path)", errno)
        }
        guard UInt64(targetInfo.st_dev) == candidate.identity.device,
              UInt64(targetInfo.st_ino) == candidate.identity.inode else {
            throw SecureDeletionError.identityChanged
        }
        guard (targetInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw SafetyPolicyError.refused("Cleanup targets must be directories.")
        }

        let targetFD = openat(parentFD, targetName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard targetFD >= 0 else {
            throw SecureDeletionError.systemCall("Opening \(candidate.url.path)", errno)
        }
        defer { close(targetFD) }

        try removeChildren(of: targetFD, device: targetInfo.st_dev, displayPath: candidate.url.path)

        if candidate.deletionMode == .item {
            guard unlinkat(parentFD, targetName, AT_REMOVEDIR) == 0 else {
                throw SecureDeletionError.systemCall("Removing \(candidate.url.path)", errno)
            }
        }
    }

    private static func openDirectoryChain(_ components: [String]) throws -> Int32 {
        var currentFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard currentFD >= 0 else {
            throw SecureDeletionError.systemCall("Opening filesystem root", errno)
        }

        for component in components {
            let nextFD = openat(currentFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if nextFD < 0 {
                let code = errno
                close(currentFD)
                throw SecureDeletionError.systemCall("Opening path component \(component)", code)
            }
            close(currentFD)
            currentFD = nextFD
        }
        return currentFD
    }

    private static func removeChildren(of directoryFD: Int32, device: dev_t, displayPath: String) throws {
        let duplicateFD = dup(directoryFD)
        guard duplicateFD >= 0, let directory = fdopendir(duplicateFD) else {
            if duplicateFD >= 0 { close(duplicateFD) }
            throw SecureDeletionError.systemCall("Reading \(displayPath)", errno)
        }
        defer { closedir(directory) }

        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }

            var info = stat()
            guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw SecureDeletionError.systemCall("Inspecting \(displayPath)/\(name)", errno)
            }

            if (info.st_mode & S_IFMT) == S_IFDIR {
                guard info.st_dev == device else {
                    throw SecureDeletionError.crossedFilesystem("\(displayPath)/\(name)")
                }
                let childFD = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard childFD >= 0 else {
                    throw SecureDeletionError.systemCall("Opening \(displayPath)/\(name)", errno)
                }
                do {
                    try removeChildren(of: childFD, device: device, displayPath: "\(displayPath)/\(name)")
                    close(childFD)
                } catch {
                    close(childFD)
                    throw error
                }
                guard unlinkat(directoryFD, name, AT_REMOVEDIR) == 0 else {
                    throw SecureDeletionError.systemCall("Removing \(displayPath)/\(name)", errno)
                }
            } else {
                guard unlinkat(directoryFD, name, 0) == 0 else {
                    throw SecureDeletionError.systemCall("Removing \(displayPath)/\(name)", errno)
                }
            }
        }
    }
}
