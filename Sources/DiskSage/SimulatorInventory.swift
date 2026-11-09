import Darwin
import Foundation

/// Offers simulator devices one at a time, and deletes one with `simctl delete <udid>`.
/// It never shuts down or deletes all devices.
enum SimulatorInventory {
    typealias Run = @Sendable ([String]) throws -> (code: Int32, data: Data)

    static let simctl: Run = { arguments in
        let output = try WorktreeGitProcess().execute("/usr/bin/xcrun", ["simctl"] + arguments)
        return (output.code, output.data)
    }

    static func devicesRoot(home: URL) -> URL {
        CleanupPath.fileURL(home.appending(path: "Library/Developer/CoreSimulator/Devices", directoryHint: .isDirectory))
    }

    static func devices(run: Run = simctl) throws -> [SimulatorDevice] {
        let output = try run(["list", "devices", "-j"])
        guard output.code == 0 else {
            throw FeatureFailure(message: "simctl could not list simulators. Nothing was deleted.")
        }
        return try SimulatorDevice.parse(output.data)
    }

    /// Shut-down devices that no process uses. Simulator data holds installed apps, so each one is a review item.
    static func candidates(activity: CleanupActivity, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           run: Run = simctl, size: (URL) -> Int64? = DiskScanner.allocatedSize) -> [CleanupCandidate] {
        guard let devices = try? devices(run: run) else { return [] }
        let root = devicesRoot(home: home)
        return devices.compactMap { device in
            guard !Task.isCancelled, device.isShutdown else { return nil }
            let url = root.appending(path: device.udid, directoryHint: .isDirectory)
            guard !activity.contains(url), let identity = identity(of: url),
                  let bytes = size(url), bytes > 0 else { return nil }
            let state = device.isAvailable ? "Shut down" : "Unavailable runtime"
            return CleanupCandidate(url: url, name: "\(device.name) (\(device.runtimeTitle))", category: .simulator,
                size: bytes, risk: .medium,
                reason: "\(state) simulator. Deleting it removes its installed apps and their data.",
                identity: identity, deletionMode: .simulatorDevice)
        }
    }

    /// Runs right before deletion: the device must still exist, be shut down, and have no process that uses it.
    static func delete(_ candidate: CleanupCandidate, activity: CleanupActivity, run: Run = simctl) throws {
        let udid = candidate.url.lastPathComponent
        guard SimulatorDevice.isUDID(udid) else {
            throw SafetyPolicyError.refused("The simulator folder name is not a device UDID.")
        }
        guard let device = try devices(run: run).first(where: { $0.udid == udid.uppercased() }) else {
            throw FeatureFailure(message: "The simulator no longer exists. Scan again.")
        }
        guard device.isShutdown else {
            throw FeatureFailure(message: "\(device.name) is \(device.state.lowercased()). Shut it down and scan again.")
        }
        try activity.requireIdle(candidate.url)
        let result = try run(["delete", device.udid])
        guard result.code == 0 else { throw SecureDeletionError.simulatorCommandFailed(result.code) }
    }

    private static func identity(of url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}
