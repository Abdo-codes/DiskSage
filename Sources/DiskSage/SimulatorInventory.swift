import Darwin
import Foundation

/// Offers simulator devices one at a time, and deletes one with `simctl delete <udid>`
/// (or `simctl --set previews delete <udid>` for Xcode SwiftUI Previews simulators).
/// It never shuts down or deletes all devices.
enum SimulatorInventory {
    enum DeviceSet: CaseIterable, Equatable, Sendable {
        case standard
        case previews

        var simctlPrefix: [String] {
            switch self {
            case .standard: []
            case .previews: ["--set", "previews"]
            }
        }

        func root(home: URL) -> URL {
            switch self {
            case .standard: SimulatorInventory.devicesRoot(home: home)
            case .previews: SimulatorInventory.previewsRoot(home: home)
            }
        }
    }

    typealias Run = @Sendable ([String]) throws -> (code: Int32, data: Data)

    static let simctl: Run = { arguments in
        // A large device can take more than the 20-second inspection limit to delete. Stopping simctl
        // part way would report a failure for a deletion that already started, so only reads time out.
        let output = try WorktreeGitProcess().execute("/usr/bin/xcrun", ["simctl"] + arguments,
                                                      allowTermination: !arguments.contains("delete"))
        return (output.code, output.data)
    }

    static func devicesRoot(home: URL) -> URL {
        CleanupPath.fileURL(home.appending(path: "Library/Developer/CoreSimulator/Devices", directoryHint: .isDirectory))
    }

    static func previewsRoot(home: URL) -> URL {
        CleanupPath.fileURL(home.appending(path: "Library/Developer/Xcode/UserData/Previews/Simulator Devices",
                                           directoryHint: .isDirectory))
    }

    static func deviceSet(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> DeviceSet? {
        let parent = CleanupPath.fileURL(url).deletingLastPathComponent()
        return DeviceSet.allCases.first { $0.root(home: home) == parent }
    }

    static func devices(in set: DeviceSet = .standard, run: Run = simctl) throws -> [SimulatorDevice] {
        let output = try run(set.simctlPrefix + ["list", "devices", "-j"])
        guard output.code == 0 else {
            throw FeatureFailure(message: "simctl could not list simulators. Nothing was deleted.")
        }
        return try SimulatorDevice.parse(output.data)
    }

    /// Shut-down devices that no process uses across standard CoreSimulator and Xcode Previews sets.
    static func candidates(activity: CleanupActivity, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           keep: KeepRules = .current(),
                           run: Run = simctl, size: (URL) -> Int64? = DiskScanner.allocatedSize) -> [CleanupCandidate] {
        var found: [CleanupCandidate] = []
        for set in DeviceSet.allCases {
            guard !Task.isCancelled else { break }
            let root = set.root(home: home)
            if set == .previews, !TemporaryBuildOutput.isRealDirectory(root) { continue }
            guard let devices = try? devices(in: set, run: run) else { continue }
            found += devices.compactMap { device in
                guard !Task.isCancelled, device.isShutdown, !keep.keepsSimulator(named: device.name) else { return nil }
                let url = root.appending(path: device.udid, directoryHint: .isDirectory)
                guard !activity.contains(url), let identity = identity(of: url),
                      let bytes = size(url), bytes > 0 else { return nil }
                let state = device.isAvailable ? "Shut down" : "Unavailable runtime"
                let name = set == .previews
                    ? "Preview · \(device.name) (\(device.runtimeTitle))"
                    : "\(device.name) (\(device.runtimeTitle))"
                let reason = set == .previews
                    ? "\(state) Xcode Previews simulator. Xcode recreates it automatically when needed."
                    : "\(state) simulator. Deleting it removes its installed apps and their data."
                return CleanupCandidate(url: url, name: name, category: .simulator,
                    size: bytes, risk: .medium, reason: reason,
                    identity: identity, deletionMode: .simulatorDevice)
            }
        }
        return found
    }

    /// Runs right before deletion: the device must still exist, be shut down, and have no process that uses it.
    static func delete(_ candidate: CleanupCandidate, activity: CleanupActivity,
                       keep: KeepRules = .current(),
                       home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       run: Run = simctl) throws {
        guard let set = deviceSet(for: candidate.url, home: home) else {
            throw SafetyPolicyError.refused("The simulator folder is not inside a known CoreSimulator device set.")
        }
        let udid = candidate.url.lastPathComponent
        guard SimulatorDevice.isUDID(udid) else {
            throw SafetyPolicyError.refused("The simulator folder name is not a device UDID.")
        }
        guard let device = try devices(in: set, run: run).first(where: { $0.udid == udid.uppercased() }) else {
            throw FeatureFailure(message: "The simulator no longer exists. Scan again.")
        }
        guard !keep.keepsSimulator(named: device.name) else {
            throw SafetyPolicyError.refused("A keep rule in Settings protects \(device.name).")
        }
        guard device.isShutdown else {
            throw FeatureFailure(message: "\(device.name) is \(device.state.lowercased()). Shut it down and scan again.")
        }
        try activity.requireIdle(candidate.url)
        let result = try run(set.simctlPrefix + ["delete", device.udid])
        guard result.code == 0 else { throw SecureDeletionError.simulatorCommandFailed(result.code) }
    }

    /// The folders of devices whose names a keep rule matches.
    static func keptDeviceFolders(_ keep: KeepRules, in set: DeviceSet = .standard, home: URL,
                                  run: Run = simctl) throws -> [URL] {
        let root = set.root(home: home)
        if set == .previews, !FileManager.default.fileExists(atPath: root.path) { return [] }
        return try devices(in: set, run: run).filter { keep.keepsSimulator(named: $0.name) }
            .map { root.appending(path: $0.udid, directoryHint: .isDirectory) }
    }

    private static func identity(of url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}
