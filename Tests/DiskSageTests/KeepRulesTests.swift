import Darwin
import Foundation
import Testing
@testable import DiskSage

struct KeepRulesTests {
    @Test func parsesPathsAndPatterns() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let rules = KeepRules.parse(paths: " ~/Movies/refs \n/private/tmp/keep/\nrelative\n/\n", simulatorNames: "lane-*, coord-*\nQA", home: home)
        #expect(rules.paths == ["/Users/someone/Movies/refs", "/private/tmp/keep"])
        #expect(rules.simulatorNames == ["lane-*", "coord-*", "QA"])
        #expect(KeepRules.invalidPaths("~/a\nrelative\n/\n/b") == ["relative", "/"])
        #expect(rules.keepsSimulator(named: "lane-3") && rules.keepsSimulator(named: "Coord-Main") && rules.keepsSimulator(named: "qa"))
        #expect(!rules.keepsSimulator(named: "iPhone 17") && !rules.keepsSimulator(named: "my-lane-1"))
    }

    @Test func keepsTheItemWhatIsInsideItAndWhatContainsIt() {
        let rules = KeepRules(paths: ["/private/tmp/claude-502/proj/abc/scratchpad"])
        #expect(rules.keeps(URL(fileURLWithPath: "/private/tmp/claude-502/proj/abc/scratchpad")))
        #expect(rules.keeps(URL(fileURLWithPath: "/private/tmp/claude-502/proj/abc/scratchpad/clip.mov")))
        #expect(rules.keeps(URL(fileURLWithPath: "/private/tmp/claude-502/PROJ")))
        #expect(!rules.keeps(URL(fileURLWithPath: "/private/tmp/claude-502/proj/abc/scratchpad-2")))
        #expect(!rules.keeps(URL(fileURLWithPath: "/private/tmp/claude-502/other")))
    }

    @Test func policyRefusesKeptItems() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write("Library/Caches/com.example/a.bin")
        let folder = CleanupPath.fileURL(f.base.appending(path: "Library/Caches/com.example"))
        var info = stat(); _ = lstat(folder.path, &info)
        let candidate = CleanupCandidate(url: folder, name: "x", category: .cache, size: 1, risk: .low, reason: "",
            identity: FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)), deletionMode: .item)
        let kept = SafetyPolicy(home: f.base, keep: KeepRules(paths: [folder.path + "/a.bin"]))
        #expect(throws: (any Error).self) { try kept.validate(candidate) }
    }

    @Test func keptSimulatorsAreNeverOfferedOrDeleted() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let udid = "44444444-4444-4444-4444-444444444444"
        try f.write("Library/Developer/CoreSimulator/Devices/\(udid)/data/app.bin")
        let run: SimulatorInventory.Run = { arguments in
            if arguments.first == "delete" { Issue.record("A kept simulator was deleted.") }
            let json = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"udid":"\#(udid)","name":"lane-7","state":"Shutdown","isAvailable":true}]}}"#
            return (0, Data(json.utf8))
        }
        let rules = KeepRules(simulatorNames: ["lane-*"])
        #expect(SimulatorInventory.candidates(activity: .idle, home: f.base, keep: rules, run: run).isEmpty)
        let offered = try #require(SimulatorInventory.candidates(activity: .idle, home: f.base, keep: KeepRules(), run: run).first)
        #expect(throws: (any Error).self) { try SimulatorInventory.delete(offered, activity: .idle, keep: rules, run: run) }
    }

    @Test func agentFoldersWithVideosAreHighRisk() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write(".codex/visualizations/2026/10/22/run/shot.png")
        let day = CleanupPath.fileURL(f.base.appending(path: ".codex/visualizations/2026/10/22"))
        let plain = try #require(TemporaryBuildInspector.inspect(day, activity: .idle, now: f.later(hours: 200), home: f.base))
        #expect(plain.risk == .low)
        try f.write(".codex/visualizations/2026/10/22/run/clip.MOV")
        let video = try #require(TemporaryBuildInspector.inspect(day, activity: .idle, now: f.later(hours: 200), home: f.base))
        #expect(video.risk == .high && video.reason.contains("video"))
        // A candidate made before the video appeared is refused before deletion.
        #expect(throws: (any Error).self) {
            try TemporaryBuildInspector.verifyBeforeDeletion(plain, activity: .idle, now: f.later(hours: 200), home: f.base)
        }
    }

    @Test func schedulesRefuseFoldersThatHoldAKeptPath() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let folder = try f.folder("Downloads/inbox")
        try f.write("Downloads/inbox/reference.mov")
        let schedule = CleanupSchedule(folder: folder, folderIdentity: try ScheduledFolderPolicy.identity(of: folder),
                                       scope: .folderContents)
        try ScheduledFolderPolicy.validate(schedule, keep: KeepRules())
        #expect(throws: (any Error).self) {
            try ScheduledFolderPolicy.validate(schedule, keep: KeepRules(paths: [folder.path + "/reference.mov"]))
        }
    }

    @Test func keptCheckoutsAreBlocked() throws {
        let f = try WorktreeFixture(); defer { f.dispose() }
        let inspector = WorktreeInspector(checkActivity: false, keep: KeepRules(paths: [f.checkout.path]))
        let item = inspector.inspect(try f.item(), configuration: f.configuration)
        #expect(item.blockers.contains("A keep rule in Settings protects this checkout."))
        #expect(!item.canRemove)
    }

    @Test func schedulesOverSimulatorDataRespectKeptNames() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let kept = "55555555-5555-5555-5555-555555555555", other = "66666666-6666-6666-6666-666666666666"
        try f.write("Library/Developer/CoreSimulator/Devices/\(kept)/data/app.bin")
        try f.write("Library/Developer/CoreSimulator/Devices/\(other)/data/app.bin")
        let run: SimulatorInventory.Run = { _ in
            let json = #"{"devices":{"r":[{"udid":"\#(kept)","name":"lane-1","state":"Shutdown","isAvailable":true},{"udid":"\#(other)","name":"iPhone","state":"Shutdown","isAvailable":true}]}}"#
            return (0, Data(json.utf8))
        }
        let rules = KeepRules(simulatorNames: ["lane-*"])
        func schedule(_ relative: String) throws -> CleanupSchedule {
            let folder = CleanupPath.fileURL(f.base.appending(path: relative))
            return CleanupSchedule(folder: folder, folderIdentity: try ScheduledFolderPolicy.identity(of: folder), scope: .folderContents)
        }
        let devices = "Library/Developer/CoreSimulator/Devices"
        #expect(throws: (any Error).self) {
            try ScheduledFolderPolicy.validate(try schedule(devices), keep: rules, home: f.base, simctl: run)
        }
        #expect(throws: (any Error).self) {
            try ScheduledFolderPolicy.validate(try schedule("\(devices)/\(kept)/data"), keep: rules, home: f.base, simctl: run)
        }
        try ScheduledFolderPolicy.validate(try schedule("\(devices)/\(other)/data"), keep: rules, home: f.base, simctl: run)
        let failing: SimulatorInventory.Run = { _ in (1, Data()) }
        #expect(throws: (any Error).self) {
            try ScheduledFolderPolicy.validate(try schedule("\(devices)/\(other)/data"), keep: rules, home: f.base, simctl: failing)
        }
    }
}
