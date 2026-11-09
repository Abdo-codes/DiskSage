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

enum CleanupProgress: Equatable, Sendable {
    case entriesRemoved(Int)
    case started(CleanupCandidate, completed: Int, total: Int)
    case finished(CleanupItemResult, completed: Int, total: Int)
}

typealias CleanupAction = @Sendable ([CleanupCandidate], CleanupTrigger,
    @escaping @Sendable (CleanupProgress) async -> Void) async -> CleanupReport

struct CleanupService: Sendable {
    // A remover calls entryRemoved synchronously on its own worker. It must not retain the callback.
    typealias Remove = @Sendable (CleanupCandidate, @escaping @Sendable () -> Void) throws -> Void
    typealias WriteEvent = @Sendable (CleanupLogEvent) throws -> Void
    let logger: CleanupLogger
    let maximumWorkers: Int
    let remove: Remove
    let writeEvent: WriteEvent

    init(logger: CleanupLogger = .shared, maximumWorkers: Int = 4,
         remove: @escaping Remove = { candidate, entryRemoved in
             // Read the kind before the policy check. A folder that stops matching after the check,
             // such as older device symbols whose newer version was deleted, still gets the full check and fails it.
             let wholeFolder = candidate.deletionMode == .item && TemporaryBuildOutput.kind(of: candidate.url) != nil
             try SafetyPolicy().validate(candidate)
             if candidate.deletionMode == .generatedFiles {
                 try GeneratedFileDeleter.delete(candidate, entryRemoved: entryRemoved)
             } else if candidate.deletionMode == .simulatorDevice {
                 try SimulatorInventory.delete(candidate, activity: try CleanupActivity.capture())
             } else {
                 let activity = try CleanupActivity.capture()
                 try activity.requireIdle(candidate.url)
                 if wholeFolder || TemporaryBuildOutput.kind(of: candidate.url) != nil {
                     try TemporaryBuildInspector.verifyBeforeDeletion(candidate, activity: activity)
                 }
                 try SecureFileDeleter.delete(candidate, entryRemoved: entryRemoved)
             }
         }, writeEvent: WriteEvent? = nil) {
        self.logger = logger
        self.maximumWorkers = min(4, max(1, maximumWorkers))
        self.remove = remove
        self.writeEvent = writeEvent ?? { try logger.append($0) }
    }

    func delete(_ candidates: [CleanupCandidate], trigger: CleanupTrigger = .manual,
                progress: @escaping @Sendable (CleanupProgress) async -> Void = { _ in }) async -> CleanupReport {
        let (updates, continuation) = AsyncStream<CleanupProgress>.makeStream()
        let reporting = Task { for await update in updates { await progress(update) } }
        let report = await CleanupScheduler(service: self, candidates: candidates, trigger: trigger,
                                            updates: continuation).run()
        continuation.finish()
        await reporting.value
        return report
    }
}

enum SecureFileDeleter {
    static func delete(_ candidate: CleanupCandidate, entryRemoved: () -> Void) throws {
        let components = CleanupPath.fileURL(candidate.url).pathComponents
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

        try removeChildren(of: targetFD, device: targetInfo.st_dev, displayPath: candidate.url.path, entryRemoved: entryRemoved)

        if candidate.deletionMode == .item {
            guard unlinkat(parentFD, targetName, AT_REMOVEDIR) == 0 else {
                throw SecureDeletionError.systemCall("Removing \(candidate.url.path)", errno)
            }
            entryRemoved()
        }
    }

    static func openDirectoryChain(_ components: [String]) throws -> Int32 {
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

    private static func removeChildren(of directoryFD: Int32, device: dev_t, displayPath: String, entryRemoved: () -> Void) throws {
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
                    try removeChildren(of: childFD, device: device, displayPath: "\(displayPath)/\(name)", entryRemoved: entryRemoved)
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
            entryRemoved()
        }
    }
}
