import Darwin
import Foundation

/// One simulator runtime disk image as `xcrun simctl runtime list -j` reports it.
struct SimulatorRuntime: Equatable, Sendable {
    let identifier: String
    let runtimeIdentifier: String
    let platformIdentifier: String
    let version: String
    let build: String
    let state: String
    let deletable: Bool
    let sizeBytes: Int64
    let path: String
    let mountPath: String?
    let runtimeBundlePath: String?
    let lastUsedAt: Date?

    var isUnusable: Bool { state.caseInsensitiveCompare("Unusable") == .orderedSame }

    var platformName: String {
        switch platformIdentifier.lowercased() {
        case "com.apple.platform.iphonesimulator": "iOS"
        case "com.apple.platform.watchsimulator": "watchOS"
        case "com.apple.platform.appletvsimulator": "tvOS"
        case "com.apple.platform.xrsimulator": "visionOS"
        default:
            SimulatorDevice(udid: identifier, name: "", state: "", runtime: runtimeIdentifier, isAvailable: true)
                .runtimeTitle.split(separator: " ").first.map(String.init) ?? "Simulator"
        }
    }

    var platformVersion: String {
        version.isEmpty ? platformName : "\(platformName) \(version)"
    }

    var title: String {
        build.isEmpty ? "\(platformVersion) runtime" : "\(platformVersion) (\(build)) runtime"
    }

    static func parse(_ data: Data) throws -> [SimulatorRuntime] {
        guard let start = data.firstIndex(of: UInt8(ascii: "{")) else {
            throw FeatureFailure(message: "The simulator runtime list could not be read. Nothing was deleted.")
        }
        struct Entry: Decodable {
            let identifier: String?
            let runtimeIdentifier: String?
            let platformIdentifier: String?
            let version: String?
            let build: String?
            let state: String?
            let deletable: Bool?
            let sizeBytes: Int64?
            let path: String?
            let mountPath: String?
            let runtimeBundlePath: String?
            let lastUsedAt: String?
        }
        let map = try JSONDecoder().decode([String: Entry].self, from: data[start...])
        let iso = ISO8601DateFormatter()
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return map.compactMap { key, entry -> SimulatorRuntime? in
            let id = (entry.identifier ?? key).uppercased()
            guard SimulatorDevice.isUDID(id),
                  let path = entry.path, !path.isEmpty,
                  let runtimeIdentifier = entry.runtimeIdentifier, !runtimeIdentifier.isEmpty else { return nil }
            let lastUsed = entry.lastUsedAt.flatMap { iso.date(from: $0) ?? isoFractional.date(from: $0) }
            return SimulatorRuntime(
                identifier: id,
                runtimeIdentifier: runtimeIdentifier,
                platformIdentifier: entry.platformIdentifier ?? "",
                version: entry.version ?? "",
                build: entry.build ?? "",
                state: entry.state ?? "",
                deletable: entry.deletable ?? false,
                sizeBytes: entry.sizeBytes ?? 0,
                path: path,
                mountPath: entry.mountPath,
                runtimeBundlePath: entry.runtimeBundlePath,
                lastUsedAt: lastUsed
            )
        }.sorted { $0.identifier < $1.identifier }
    }
}

/// Offers deletable simulator runtimes that are either unusable or unused by any simulator device,
/// and removes them one at a time via `xcrun simctl runtime delete <identifier>`.
enum SimulatorRuntimeInventory {
    static let minimumIdleForReadyUnused: TimeInterval = 24 * 3_600

    static func runtimes(run: SimulatorInventory.Run = SimulatorInventory.simctl) throws -> [SimulatorRuntime] {
        let output = try run(["runtime", "list", "-j"])
        guard output.code == 0 else {
            throw FeatureFailure(message: "simctl could not list simulator runtimes. Nothing was deleted.")
        }
        return try SimulatorRuntime.parse(output.data)
    }

    static func candidates(
        activity: CleanupActivity,
        now: Date = Date(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        keep: KeepRules = .current(),
        run: SimulatorInventory.Run = SimulatorInventory.simctl
    ) -> [CleanupCandidate] {
        guard let listed = try? runtimes(run: run) else { return [] }
        // If listing devices fails, only unusable runtimes may be offered; never assume a Ready runtime is unused.
        let usedRuntimes = try? activeDeviceRuntimes(home: home, run: run)

        return listed.compactMap { runtime in
            guard !Task.isCancelled, runtime.deletable, runtime.sizeBytes > 0 else { return nil }
            let url = CleanupPath.fileURL(URL(fileURLWithPath: runtime.path))
            guard !isKept(runtime, url: url, keep: keep),
                  !isBusy(runtime, url: url, activity: activity),
                  let identity = identity(of: url) else { return nil }
            guard let reason = eligibilityReason(runtime, usedRuntimes: usedRuntimes, now: now) else { return nil }
            let candidate = CleanupCandidate(
                url: url,
                name: runtime.title,
                category: .simulator,
                size: runtime.sizeBytes,
                risk: .medium,
                reason: reason,
                identity: identity,
                deletionMode: .simulatorRuntime,
                simulatorRuntimeID: runtime.identifier
            )
            guard (try? SafetyPolicy(home: home, now: now, keep: keep).validate(candidate)) != nil else { return nil }
            return candidate
        }
    }

    /// Re-verifies live runtime state, device references, keep rules, and process activity before deleting.
    static func delete(
        _ candidate: CleanupCandidate,
        activity: CleanupActivity,
        now: Date = Date(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        keep: KeepRules = .current(),
        run: SimulatorInventory.Run = SimulatorInventory.simctl
    ) throws {
        guard let id = candidate.simulatorRuntimeID?.uppercased(), SimulatorDevice.isUDID(id) else {
            throw SafetyPolicyError.refused("A simulator runtime candidate must carry a valid runtime UUID.")
        }
        guard let runtime = try runtimes(run: run).first(where: { $0.identifier == id }) else {
            throw FeatureFailure(message: "The simulator runtime no longer exists. Scan again.")
        }
        guard runtime.deletable else {
            throw SafetyPolicyError.refused("\(runtime.title) is marked non-deletable by CoreSimulator.")
        }
        let url = CleanupPath.fileURL(URL(fileURLWithPath: runtime.path))
        guard url == CleanupPath.fileURL(candidate.url) else {
            throw SafetyPolicyError.refused("The simulator runtime path changed after scanning. Scan again.")
        }
        guard !isKept(runtime, url: url, keep: keep) else {
            throw SafetyPolicyError.refused("A keep rule in Settings protects \(runtime.title).")
        }
        try requireIdle(runtime, url: url, activity: activity)
        if !runtime.isUnusable {
            let usedRuntimes = try activeDeviceRuntimes(home: home, run: run)
            guard eligibilityReason(runtime, usedRuntimes: usedRuntimes, now: now) != nil else {
                throw FeatureFailure(message: "\(runtime.title) is used by a simulator or changed recently. Scan again.")
            }
        }
        let result = try run(["runtime", "delete", runtime.identifier])
        guard result.code == 0 else { throw SecureDeletionError.simulatorCommandFailed(result.code) }
    }

    private static func eligibilityReason(_ runtime: SimulatorRuntime, usedRuntimes: Set<String>?, now: Date) -> String? {
        if runtime.isUnusable {
            return "Unusable simulator runtime image. Deleting it via simctl reclaims disk space without affecting working simulators."
        }
        guard runtime.state.caseInsensitiveCompare("Ready") == .orderedSame,
              let usedRuntimes, !usedRuntimes.contains(runtime.runtimeIdentifier) else { return nil }
        if let lastUsed = runtime.lastUsedAt, now.timeIntervalSince(lastUsed) < minimumIdleForReadyUnused {
            return nil
        }
        return "Unused simulator runtime with no configured devices. Xcode can download it again if needed."
    }

    private static func activeDeviceRuntimes(home: URL, run: SimulatorInventory.Run) throws -> Set<String> {
        var used = Set<String>()
        for set in SimulatorInventory.DeviceSet.allCases {
            let root = set.root(home: home)
            if set == .previews, !FileManager.default.fileExists(atPath: root.path) { continue }
            for device in try SimulatorInventory.devices(in: set, run: run) {
                used.insert(device.runtime)
            }
        }
        return used
    }

    private static func isKept(_ runtime: SimulatorRuntime, url: URL, keep: KeepRules) -> Bool {
        if keep.keeps(url) { return true }
        if let mount = runtime.mountPath, keep.keeps(CleanupPath.fileURL(URL(fileURLWithPath: mount))) { return true }
        if let bundle = runtime.runtimeBundlePath, keep.keeps(CleanupPath.fileURL(URL(fileURLWithPath: bundle))) { return true }
        return keep.keepsSimulator(named: runtime.title) || keep.keepsSimulator(named: runtime.platformVersion)
    }

    private static func isBusy(_ runtime: SimulatorRuntime, url: URL, activity: CleanupActivity) -> Bool {
        if activity.contains(url) { return true }
        if let mount = runtime.mountPath, activity.contains(CleanupPath.fileURL(URL(fileURLWithPath: mount))) { return true }
        if let bundle = runtime.runtimeBundlePath, activity.contains(CleanupPath.fileURL(URL(fileURLWithPath: bundle))) { return true }
        return false
    }

    private static func requireIdle(_ runtime: SimulatorRuntime, url: URL, activity: CleanupActivity) throws {
        guard !isBusy(runtime, url: url, activity: activity) else {
            throw FeatureFailure(message: "\(runtime.title) is in use. Close Simulator or Xcode and scan again.")
        }
    }

    private static func identity(of url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}
