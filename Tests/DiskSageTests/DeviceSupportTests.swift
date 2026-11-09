import Foundation
import Testing
@testable import DiskSage

/// The fixture folder stands in for the home folder.
struct DeviceSupportTests {
    let root = "Library/Developer/Xcode/iOS DeviceSupport"

    @Test func parsesFolderNamesWithAndWithoutAModel() throws {
        let full = try #require(DeviceSupportVersion(name: "iPhone15,2 17.0.3 (21A360) arm64e"))
        #expect(full.model == "iPhone15,2" && full.version == [17, 0, 3] && full.build == "21A360" && full.architecture == "arm64e")
        let old = try #require(DeviceSupportVersion(name: "16.4 (20F66)"))
        #expect(old.model.isEmpty && old.version == [16, 4] && old.architecture.isEmpty)
        for name in ["iPhone15,2 17.0", "Notes", "iPhone15,2 x.1 (21A360)", "a b c 17.0 (21A360)", "17.0 (21A-360)", "17.0 ()"] {
            #expect(DeviceSupportVersion(name: name) == nil, "\(name)")
        }
        #expect(try #require(DeviceSupportVersion(name: "17.1 (A)")).isNewer(than: old))
        #expect(!old.isNewer(than: try #require(DeviceSupportVersion(name: "16.4.0 (20F67)"))))
    }

    @Test func onlyOlderVersionsOfTheSameDeviceAreOffered() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        for name in ["iPhone15,2 17.0 (21A329)", "iPhone15,2 18.1 (22B83)", "iPhone16,1 17.0 (21A329)",
                     "16.4 (20F66)", "Notes"] {
            try f.write("\(root)/\(name)/Symbols/usr/lib/dyld")
        }
        func kind(_ name: String) -> TemporaryBuildOutput.Kind? {
            TemporaryBuildOutput.kind(of: f.base.appending(path: "\(root)/\(name)"), home: f.base)
        }
        #expect(kind("iPhone15,2 17.0 (21A329)") == .olderDeviceSupport)
        #expect(kind("16.4 (20F66)") == .olderDeviceSupport)
        // The newest version per device, other devices and unknown folders stay.
        #expect(kind("iPhone15,2 18.1 (22B83)") == nil)
        #expect(kind("iPhone16,1 17.0 (21A329)") == nil)
        #expect(kind("Notes") == nil)
        let found = Set(AgentWorkspaceDiscovery.folders(home: f.base).map(\.lastPathComponent))
        #expect(found.isSuperset(of: ["iPhone15,2 17.0 (21A329)", "16.4 (20F66)"]))
        #expect(!found.contains("iPhone15,2 18.1 (22B83)"))
    }

    @Test func olderVersionIsOfferedAfterADayAndPassesTheChecksBeforeDeletion() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        try f.write("\(root)/iPhone15,2 17.0 (21A329)/Symbols/usr/lib/dyld")
        try f.write("\(root)/iPhone15,2 18.1 (22B83)/Symbols/usr/lib/dyld")
        let old = CleanupPath.fileURL(f.base.appending(path: "\(root)/iPhone15,2 17.0 (21A329)"))
        #expect(TemporaryBuildInspector.inspect(old, activity: .idle, now: f.later(hours: 2), home: f.base) == nil)
        let candidate = try #require(TemporaryBuildInspector.inspect(old, activity: .idle, now: f.later(hours: 30), home: f.base))
        #expect(candidate.risk == .low && candidate.deletionMode == .item && candidate.category == .cache)
        try SafetyPolicy(home: f.base, now: f.later(hours: 30)).validate(candidate)
        try TemporaryBuildInspector.verifyBeforeDeletion(candidate, activity: .idle, now: f.later(hours: 30), home: f.base)
        // If the newer version is deleted first, the older one is the newest again and stays.
        try FileManager.default.removeItem(at: f.base.appending(path: "\(root)/iPhone15,2 18.1 (22B83)"))
        #expect(throws: (any Error).self) {
            try TemporaryBuildInspector.verifyBeforeDeletion(candidate, activity: .idle, now: f.later(hours: 30), home: f.base)
        }
        #expect(throws: (any Error).self) { try SafetyPolicy(home: f.base, now: f.later(hours: 30)).validate(candidate) }
    }
}
