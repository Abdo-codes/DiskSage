import Foundation
import Testing
@testable import DiskSage

private final class FakeRuntimeSimctl: @unchecked Sendable {
    private let lock = NSLock()
    var runtimesJSON: String
    var standardDevicesJSON: String
    var previewDevicesJSON: String
    var failDeviceListing = false
    private(set) var calls: [[String]] = []

    init(runtimesJSON: String, standardDevicesJSON: String = #"{"devices":{}}"#, previewDevicesJSON: String = #"{"devices":{}}"#) {
        self.runtimesJSON = runtimesJSON
        self.standardDevicesJSON = standardDevicesJSON
        self.previewDevicesJSON = previewDevicesJSON
    }

    var run: SimulatorInventory.Run {
        { [self] arguments in
            lock.withLock {
                calls.append(arguments)
                if arguments == ["runtime", "list", "-j"] {
                    return (0, Data(runtimesJSON.utf8))
                }
                if arguments.starts(with: ["runtime", "delete"]) {
                    return (0, Data())
                }
                if failDeviceListing {
                    return (1, Data("simctl failed".utf8))
                }
                if arguments.starts(with: ["--set", "previews"]) {
                    return (0, Data(previewDevicesJSON.utf8))
                }
                return (0, Data(standardDevicesJSON.utf8))
            }
        }
    }
}

struct SimulatorRuntimeInventoryTests {
    let unusableID = "11111111-AAAA-AAAA-AAAA-111111111111"
    let unusedReadyID = "22222222-BBBB-BBBB-BBBB-222222222222"
    let usedReadyID = "33333333-CCCC-CCCC-CCCC-333333333333"
    let recentReadyID = "44444444-DDDD-DDDD-DDDD-444444444444"
    let nonDeletableID = "55555555-EEEE-EEEE-EEEE-555555555555"

    @Test func offersUnusableAndIdleUnusedRuntimesWhileProtectingInUseAndRecentOnes() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let p1 = try f.folder("runtimes/unusable")
        let p2 = try f.folder("runtimes/unused")
        let p3 = try f.folder("runtimes/used")
        let p4 = try f.folder("runtimes/recent")
        let p5 = try f.folder("runtimes/nondeletable")
        let now = ISO8601DateFormatter().date(from: "2026-11-22T12:00:00Z")!

        let json = """
        warning: preamble
        {
          "\(unusableID)": {
            "identifier": "\(unusableID)",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2-old",
            "platformIdentifier": "com.apple.platform.iphonesimulator",
            "version": "27.2",
            "build": "24B91016s",
            "state": "Unusable",
            "deletable": true,
            "sizeBytes": 8300000000,
            "path": "\(p1.path)",
            "lastUsedAt": "2026-11-22T11:30:00Z"
          },
          "\(unusedReadyID)": {
            "identifier": "\(unusedReadyID)",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-26-0",
            "platformIdentifier": "com.apple.platform.watchsimulator",
            "version": "26.0",
            "build": "23S100",
            "state": "Ready",
            "deletable": true,
            "sizeBytes": 3800000000,
            "path": "\(p2.path)",
            "lastUsedAt": "2026-11-10T10:00:00Z"
          },
          "\(usedReadyID)": {
            "identifier": "\(usedReadyID)",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
            "platformIdentifier": "com.apple.platform.iphonesimulator",
            "version": "27.2",
            "build": "24B114",
            "state": "Ready",
            "deletable": true,
            "sizeBytes": 8300000000,
            "path": "\(p3.path)",
            "lastUsedAt": "2026-11-10T10:00:00Z"
          },
          "\(recentReadyID)": {
            "identifier": "\(recentReadyID)",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.tvOS-27-0",
            "platformIdentifier": "com.apple.platform.appletvsimulator",
            "version": "27.0",
            "build": "24J10",
            "state": "Ready",
            "deletable": true,
            "sizeBytes": 4000000000,
            "path": "\(p4.path)",
            "lastUsedAt": "2026-11-22T08:00:00Z"
          },
          "\(nonDeletableID)": {
            "identifier": "\(nonDeletableID)",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.visionOS-27-0",
            "platformIdentifier": "com.apple.platform.xrsimulator",
            "version": "27.0",
            "build": "24O10",
            "state": "Ready",
            "deletable": false,
            "sizeBytes": 9000000000,
            "path": "\(p5.path)"
          }
        }
        """
        let devices = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-2":[{"udid":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","name":"iPhone 17","state":"Shutdown","isAvailable":true}]}}
        """
        let simctl = FakeRuntimeSimctl(runtimesJSON: json, standardDevicesJSON: devices)

        let found = SimulatorRuntimeInventory.candidates(activity: .idle, now: now, home: f.base, run: simctl.run)
        #expect(Set(found.compactMap(\.simulatorRuntimeID)) == Set([unusableID, unusedReadyID]))
        #expect(found.allSatisfy { $0.risk == .medium && $0.category == .simulator && $0.deletionMode == .simulatorRuntime })

        // If device listing fails, Ready runtimes are never assumed unused; only Unusable stays offered.
        simctl.failDeviceListing = true
        let fallback = SimulatorRuntimeInventory.candidates(activity: .idle, now: now, home: f.base, run: simctl.run)
        #expect(fallback.compactMap(\.simulatorRuntimeID) == [unusableID])
    }

    @Test func revalidatesDeviceUsageActivityKeepRulesAndDeletesSingleRuntimeByUUID() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let p = try f.folder("runtimes/watch")
        let mount = try f.folder("mnt/watch")
        let now = ISO8601DateFormatter().date(from: "2026-11-22T12:00:00Z")!

        let json = """
        {
          "\(unusedReadyID)": {
            "identifier": "\(unusedReadyID)",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-26-0",
            "platformIdentifier": "com.apple.platform.watchsimulator",
            "version": "26.0",
            "build": "23S100",
            "state": "Ready",
            "deletable": true,
            "sizeBytes": 3800000000,
            "path": "\(p.path)",
            "mountPath": "\(mount.path)",
            "lastUsedAt": "2026-11-10T10:00:00Z"
          }
        }
        """
        let simctl = FakeRuntimeSimctl(runtimesJSON: json)
        let candidate = try #require(SimulatorRuntimeInventory.candidates(activity: .idle, now: now, home: f.base, run: simctl.run).first)
        try SafetyPolicy(home: f.base, now: now).validate(candidate)

        // Open file under mountPath blocks deletion.
        let busyMount = CleanupActivity(paths: [mount.path + "/System/file"])
        #expect(throws: (any Error).self) {
            try SimulatorRuntimeInventory.delete(candidate, activity: busyMount, now: now, home: f.base, run: simctl.run)
        }

        // Keep rule matching runtime name blocks deletion.
        #expect(throws: SafetyPolicyError.self) {
            try SimulatorRuntimeInventory.delete(candidate, activity: .idle, now: now, home: f.base,
                                                 keep: KeepRules(simulatorNames: ["watchOS*"]), run: simctl.run)
        }

        // A new device created for this runtime after the scan blocks deletion.
        simctl.standardDevicesJSON = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.watchOS-26-0":[{"udid":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","name":"Watch","state":"Shutdown","isAvailable":true}]}}
        """
        #expect(throws: (any Error).self) {
            try SimulatorRuntimeInventory.delete(candidate, activity: .idle, now: now, home: f.base, run: simctl.run)
        }

        // Once unused again, deletes only this exact runtime UUID.
        simctl.standardDevicesJSON = #"{"devices":{}}"#
        try SimulatorRuntimeInventory.delete(candidate, activity: .idle, now: now, home: f.base, run: simctl.run)
        #expect(simctl.calls.filter { $0.starts(with: ["runtime", "delete"]) } == [["runtime", "delete", unusedReadyID]])
    }

    @Test func schedulerSerializesSimulatorRuntimesWithDevices() {
        let a = CleanupCandidate(url: URL(fileURLWithPath: "/a"), name: "r", category: .simulator, size: 1, risk: .medium, reason: "", deletionMode: .simulatorRuntime)
        let b = CleanupCandidate(url: URL(fileURLWithPath: "/b"), name: "d", category: .simulator, size: 1, risk: .medium, reason: "", deletionMode: .simulatorDevice)
        #expect(CleanupScheduler.conflicts(a, b))
        #expect(CleanupScheduler.conflicts(a, a))
    }
}
