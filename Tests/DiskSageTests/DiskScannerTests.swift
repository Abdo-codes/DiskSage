import Foundation
import Testing
@testable import DiskSage

struct DiskScannerTests {
    @Test func everyScannedCandidatePassesDeletionPolicy() async throws {
        let fakeHome = URL(fileURLWithPath: "/private/tmp/DS-test-home-\(UUID())", isDirectory: true)
        let root = fakeHome.appending(path: "Developer/scanner-test")
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let paths = [root.appending(path: "Project/.build", directoryHint: .isDirectory), root.appending(path: "Other/build", directoryHint: .isDirectory), root.appending(path: "Unrecognized", directoryHint: .isDirectory)]
        for path in paths {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: path.appending(path: "artifact"))
        }
        let locations = paths.map {
            DiskScanner.Location(url: $0, name: $0.lastPathComponent, category: .build, risk: .low,
                                 reason: "Generated fixture", deletionMode: .item)
        }
        let candidates = try await DiskScanner(locations: locations, home: fakeHome).scan()
        #expect(Set(candidates.map(\.url)) == Set(paths.prefix(2)))
        for candidate in candidates { try SafetyPolicy(home: fakeHome).validate(candidate) }
    }

    @Test func generatedRootAboveTheInventoryLimitIsReportedAndNotOffered() async throws {
        let fakeHome = URL(fileURLWithPath: "/private/tmp/DS-test-home-\(UUID())", isDirectory: true)
        let base = fakeHome.appending(path: "Developer/limit-test")
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let small = base.appending(path: "Small/.build", directoryHint: .isDirectory)
        let large = base.appending(path: "Large/.build", directoryHint: .isDirectory)
        for (root, count) in [(small, 1), (large, 5)] {
            try FileManager.default.createDirectory(at: root.appending(path: "debug"), withIntermediateDirectories: true)
            for index in 0..<count { try Data(repeating: 1, count: 4096).write(to: root.appending(path: "debug/\(index).o")) }
        }
        let locations = [(small, "Small build"), (large, "Large build")].map {
            DiskScanner.Location(url: $0.0, name: $0.1, category: .build, risk: .low, reason: "Fixture", deletionMode: .generatedFiles)
        }
        let report = try await DiskScanner(locations: locations, activity: { .idle }, inventoryLimit: 4, home: fakeHome).report()
        #expect(report.candidates.isEmpty)
        #expect(report.warnings == ["Large build was skipped. \(InventoryLimitExceeded(limit: 4).localizedDescription)"])
    }

    @Test func scannerNeverOffersItsOwnExecutableTree() async throws {
        let executable = try #require(Bundle.main.executableURL?.standardizedFileURL)
        let location = DiskScanner.Location(url: executable.deletingLastPathComponent(), name: "Running app",
            category: .build, risk: .low, reason: "Fixture", deletionMode: .item)
        let candidates = try await DiskScanner(locations: [location]).scan()
        #expect(candidates.isEmpty)
    }

    @Test func packageDirectoriesContributeTheirContentsToSize() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DiskSage-size-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appending(path: "Example.app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 64 * 1024).write(to: resources.appending(path: "payload.bin"))
        #expect(try #require(DiskScanner.allocatedSize(of: root)) >= 64 * 1024)
    }

    @Test func parallelSeedInspectionPreservesDeterministicOrderDeduplicationAndWarnings() async throws {
        let fakeHome = URL(fileURLWithPath: "/private/tmp/DS-test-home-\(UUID())", isDirectory: true)
        let base = fakeHome.appending(path: "Developer/parallel-test")
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let zeta = base.appending(path: "Zeta/.build", directoryHint: .isDirectory)
        let alpha = base.appending(path: "Alpha/.build", directoryHint: .isDirectory)
        let overflowA = base.appending(path: "OverflowA/.build", directoryHint: .isDirectory)
        let overflowB = base.appending(path: "OverflowB/.build", directoryHint: .isDirectory)
        for path in [zeta, alpha] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4_096).write(to: path.appending(path: "artifact"))
        }
        for path in [overflowA, overflowB] {
            try FileManager.default.createDirectory(at: path.appending(path: "debug"), withIntermediateDirectories: true)
            for i in 0..<5 { try Data(repeating: 2, count: 4_096).write(to: path.appending(path: "debug/\(i).o")) }
        }
        let locations = [
            DiskScanner.Location(url: zeta, name: "Zeta", category: .build, risk: .low, reason: "Fixture", deletionMode: .item),
            DiskScanner.Location(url: alpha, name: "Alpha", category: .build, risk: .low, reason: "Fixture", deletionMode: .item),
            // Duplicate of Alpha must be deduplicated cleanly.
            DiskScanner.Location(url: alpha, name: "Alpha dup", category: .build, risk: .low, reason: "Fixture", deletionMode: .item),
            DiskScanner.Location(url: overflowA, name: "Overflow A", category: .build, risk: .low, reason: "Fixture", deletionMode: .generatedFiles),
            DiskScanner.Location(url: overflowB, name: "Overflow B", category: .build, risk: .low, reason: "Fixture", deletionMode: .generatedFiles),
        ]
        let report = try await DiskScanner(locations: locations, activity: { .idle }, inventoryLimit: 4, maxConcurrency: 4, home: fakeHome).report()
        // Equal-sized candidates tie-break deterministically by path (Alpha before Zeta).
        #expect(report.candidates.map(\.name) == ["Alpha", "Zeta"])
        // Warnings preserve deterministic seed order regardless of task completion order.
        let limitMessage = InventoryLimitExceeded(limit: 4).localizedDescription
        #expect(report.warnings == [
            "Overflow A was skipped. \(limitMessage)",
            "Overflow B was skipped. \(limitMessage)",
        ])
    }

    @Test func cancellingScanReturnsEmptyReportCleanly() async throws {
        let task = Task {
            try await DiskScanner(locations: [], activity: {
                while !Task.isCancelled { usleep(5_000) }
                return .idle
            }).report()
        }
        task.cancel()
        let report = try await task.value
        #expect(report.candidates.isEmpty)
        #expect(report.warnings.isEmpty)
    }

    @Test func configurableMaximumCandidatesAllowsOver100WhileDefaultCapsAt100() async throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        var locations: [DiskScanner.Location] = []
        for index in 0..<105 {
            let folder = f.base.appending(path: "Developer/p-\(index)/.build", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 64).write(to: folder.appending(path: "artifact"))
            locations.append(.init(url: folder, name: "p-\(index)/.build", category: .build,
                                   risk: .low, reason: "Fixture", deletionMode: .item))
        }
        let defaultCandidates = try await DiskScanner(locations: locations, activity: { .idle }, home: f.base).scan()
        #expect(defaultCandidates.count == 100)

        let expanded = try await DiskScanner(locations: locations, activity: { .idle },
                                             maximumCandidates: 120, home: f.base).scan()
        #expect(expanded.count == 105)
    }

    @Test func temporaryBuildScanHonorsCustomHomeAndCleanupServiceEndToEndDeletesRecentTargets() async throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let future = f.later(hours: 48)
        let swiftPMManifests = "Library/Caches/org.swift.swiftpm/manifests"
        let hfHub = ".cache/huggingface/hub"
        let shipIt = "Library/Caches/com.example.App.ShipIt"
        let archive = "Library/Developer/Xcode/Archives/2026-10-01/OldApp.xcarchive"
        let orphanedDD = "Library/Developer/Xcode/DerivedData/OrphanedApp-abcdefghijklmnopqrstuvwxyzab"

        try f.write("\(swiftPMManifests)/manifest.db", bytes: 8_192)
        try f.write("\(hfHub)/models--org--demo/weights.bin", bytes: 8_192)
        try f.write(".cache/huggingface/token", bytes: 64)
        try f.write("\(shipIt)/update.zip", bytes: 8_192)
        try f.write("\(archive)/Info.plist", bytes: 64)
        try f.write("\(archive)/Products/App.bin", bytes: 8_192)
        try f.write("\(orphanedDD)/Build/Intermediates.noindex/a.o", bytes: 8_192)
        let missingWorkspace = f.base.appending(path: "Developer/DeletedWorkspace/App.xcodeproj").path
        let plistData = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": missingWorkspace], format: .xml, options: 0)
        try plistData.write(to: f.base.appending(path: "\(orphanedDD)/info.plist"))

        // TemporaryBuildInspector.scan with default extraFolders must honor custom `home`.
        let tempResult = TemporaryBuildInspector.scan(discovered: [], activity: .idle, now: future, home: f.base)
        let ecoCandidates = EcosystemCacheInventory.candidates(activity: .idle, now: future, home: f.base, minimumBytes: 1)
        let scanned = DiskScanner.validated(tempResult.candidates + ecoCandidates, home: f.base)

        let expectedTargets = [
            f.base.appending(path: swiftPMManifests),
            f.base.appending(path: hfHub),
            f.base.appending(path: shipIt),
            f.base.appending(path: archive),
            f.base.appending(path: orphanedDD),
        ].map { CleanupPath.fileURL($0).path }

        let matched = scanned.filter { expectedTargets.contains(CleanupPath.fileURL($0.url).path) }
        #expect(Set(matched.map { CleanupPath.fileURL($0.url).path }) == Set(expectedTargets))

        let logDir = f.base.appending(path: "logs")
        let service = CleanupService(logger: CleanupLogger(directory: logDir), home: f.base, now: { future }, activity: { .idle })
        let report = await service.delete(matched, trigger: .manual)
        #expect(report.failures.isEmpty)
        #expect(report.items.filter(\.succeeded).count == expectedTargets.count)
        // Hugging Face auth token outside hub/xet stays untouched.
        #expect(FileManager.default.fileExists(atPath: f.base.appending(path: ".cache/huggingface/token").path))
        // Contents-mode caches keep their directory but are now empty; item-mode archive & orphaned DerivedData are removed.
        #expect(!FileManager.default.fileExists(atPath: f.base.appending(path: archive).path))
        #expect(!FileManager.default.fileExists(atPath: f.base.appending(path: orphanedDD).path))
        #expect((try FileManager.default.contentsOfDirectory(atPath: f.base.appending(path: hfHub).path)).isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DISKSAGE_LIVE_SCAN_TEST"] == "1"))
    func liveScanCandidatesPassPolicyOnThisMac() async throws {
        let candidates = try await DiskScanner().scan()
        for candidate in candidates {
            do { try SafetyPolicy().validate(candidate) }
            catch { Issue.record(error, Comment(rawValue: "Candidate: \(candidate.url.path)")) }
        }
    }
}
