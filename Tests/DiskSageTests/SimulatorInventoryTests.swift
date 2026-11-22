import Foundation
import Testing
@testable import DiskSage

/// Records every simctl call and answers `list` with fixed device lists for standard and previews sets.
private final class FakeSimctl: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: String]
    private var previewStates: [String: String]
    private(set) var calls: [[String]] = []

    init(_ states: [String: String], previews: [String: String] = [:]) {
        self.states = states
        self.previewStates = previews
    }

    func set(_ udid: String, _ state: String) { lock.withLock { states[udid] = state } }
    func setPreview(_ udid: String, _ state: String) { lock.withLock { previewStates[udid] = state } }

    var run: SimulatorInventory.Run {
        { [self] arguments in
            lock.withLock {
                calls.append(arguments)
                let isPreviews = arguments.starts(with: ["--set", "previews"])
                let command = isPreviews ? Array(arguments.dropFirst(2)) : arguments
                if command.first == "delete" {
                    if isPreviews { previewStates[command[1]] = nil } else { states[command[1]] = nil }
                    return (0, Data())
                }
                let map = isPreviews ? previewStates : states
                let entries = map.sorted { $0.key < $1.key }.map { udid, state in
                    #"{"udid":"\#(udid)","name":"Device \#(udid.prefix(4))","state":"\#(state)","isAvailable":true}"#
                }
                let prefix = isPreviews ? "Using Previews Device Set: '/tmp/previews'\n" : "warning: ignore this line\n"
                let json = #"\#(prefix){"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[\#(entries.joined(separator: ","))]}}"#
                return (0, Data(json.utf8))
            }
        }
    }
}

struct SimulatorInventoryTests {
    let idle = "11111111-1111-1111-1111-111111111111"
    let booted = "22222222-2222-2222-2222-222222222222"
    let busy = "33333333-3333-3333-3333-333333333333"

    private func devices(_ f: TemporaryBuildFixture) throws -> [String: URL] {
        var urls: [String: URL] = [:]
        for udid in [idle, booted, busy] {
            try f.write("Library/Developer/CoreSimulator/Devices/\(udid)/data/app.bin")
            urls[udid] = CleanupPath.fileURL(SimulatorInventory.devicesRoot(home: f.base).appending(path: udid))
        }
        return urls
    }

    @Test func parsesTheListAfterWarningsAndNamesTheRuntime() throws {
        let simctl = FakeSimctl([idle: "Shutdown", "not-a-udid": "Shutdown"])
        let found = try SimulatorInventory.devices(run: simctl.run)
        #expect(found.map(\.udid) == [idle])
        #expect(found.first?.runtimeTitle == "iOS 27.0")
    }

    @Test func offersOnlyShutDownDevicesThatNoProcessUses() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let urls = try devices(f)
        let simctl = FakeSimctl([idle: "Shutdown", booted: "Booted", busy: "Shutdown"])
        let activity = CleanupActivity(paths: [urls[busy]!.path + "/data/Containers/App.app/App"])
        let found = SimulatorInventory.candidates(activity: activity, home: f.base, run: simctl.run)
        #expect(found.map(\.url) == [urls[idle]!])
        #expect(found.allSatisfy { $0.risk == .medium && $0.deletionMode == .simulatorDevice && $0.category == .simulator })
        #expect(found.allSatisfy { (try? SafetyPolicy(home: f.base).validate($0)) != nil })
        #expect(!simctl.calls.contains { $0.contains("all") || $0.first == "shutdown" })
    }

    @Test func deletesOneDeviceAndChecksItsStateAgainFirst() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        _ = try devices(f)
        let simctl = FakeSimctl([idle: "Shutdown", booted: "Booted", busy: "Shutdown"])
        let candidate = try #require(SimulatorInventory.candidates(activity: .idle, home: f.base, run: simctl.run)
            .first { $0.url.lastPathComponent == idle })
        // The device boots after the scan: nothing is deleted.
        simctl.set(idle, "Booted")
        #expect(throws: (any Error).self) { try SimulatorInventory.delete(candidate, activity: .idle, home: f.base, run: simctl.run) }
        // A process starts to use it after the scan: nothing is deleted.
        simctl.set(idle, "Shutdown")
        let using = CleanupActivity(paths: [candidate.url.path + "/data/x"])
        #expect(throws: (any Error).self) { try SimulatorInventory.delete(candidate, activity: using, home: f.base, run: simctl.run) }
        #expect(!simctl.calls.contains { $0.first == "delete" })
        try SimulatorInventory.delete(candidate, activity: .idle, home: f.base, run: simctl.run)
        #expect(simctl.calls.filter { $0.first == "delete" } == [["delete", idle]])
    }

    @Test func offersAndDeletesShutDownXcodePreviewSimulatorsUsingPreviewsSet() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let previewIdle = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let previewBooted = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        try f.write("Library/Developer/Xcode/UserData/Previews/Simulator Devices/\(previewIdle)/data/preview.bin")
        try f.write("Library/Developer/Xcode/UserData/Previews/Simulator Devices/\(previewBooted)/data/preview.bin")
        let simctl = FakeSimctl([:], previews: [previewIdle: "Shutdown", previewBooted: "Booted"])

        let found = SimulatorInventory.candidates(activity: .idle, home: f.base, run: simctl.run)
        let candidate = try #require(found.first)
        #expect(found.count == 1)
        #expect(candidate.url == CleanupPath.fileURL(SimulatorInventory.previewsRoot(home: f.base).appending(path: previewIdle)))
        #expect(candidate.name.hasPrefix("Preview · "))
        #expect(candidate.risk == .medium && candidate.deletionMode == .simulatorDevice && candidate.category == .simulator)
        try SafetyPolicy(home: f.base).validate(candidate)

        // Booting after scan blocks deletion.
        simctl.setPreview(previewIdle, "Booted")
        #expect(throws: (any Error).self) { try SimulatorInventory.delete(candidate, activity: .idle, home: f.base, run: simctl.run) }

        // Shut down again -> deletes via `--set previews delete <udid>`.
        simctl.setPreview(previewIdle, "Shutdown")
        try SimulatorInventory.delete(candidate, activity: .idle, home: f.base, run: simctl.run)
        #expect(simctl.calls.contains(["--set", "previews", "delete", previewIdle]))
    }

    @Test func policyAllowsOnlyOneDeviceFolder() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let urls = try devices(f)
        let policy = SafetyPolicy(home: f.base)
        func candidate(_ url: URL, mode: DeletionMode) -> CleanupCandidate {
            var info = stat(); _ = lstat(url.path, &info)
            return CleanupCandidate(url: url, name: "x", category: .simulator, size: 1, risk: .medium, reason: "",
                identity: FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)), deletionMode: mode)
        }
        let root = SimulatorInventory.devicesRoot(home: f.base)
        let other = try f.folder("Library/Developer/CoreSimulator/Devices/not-a-device")
        #expect((try? policy.validate(candidate(urls[idle]!, mode: .simulatorDevice))) != nil)
        #expect(throws: (any Error).self) { try policy.validate(candidate(root, mode: .simulatorDevice)) }
        #expect(throws: (any Error).self) { try policy.validate(candidate(other, mode: .simulatorDevice)) }
        #expect(throws: (any Error).self) { try policy.validate(candidate(root, mode: .simulatorDevices)) }
    }
}
