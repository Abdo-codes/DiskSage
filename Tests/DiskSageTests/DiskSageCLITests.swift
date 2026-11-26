import Foundation
import Testing
@testable import DiskSage

struct DiskSageCLITests {
    @Test func ignoresEmptyAndMacOSLaunchServicesArguments() {
        #expect(DiskSageCLI.parse([]) == nil)
        #expect(DiskSageCLI.parse(["-psn_0_123456"]) == nil)
        #expect(DiskSageCLI.parse(["-NSDocumentRevisionsDebugMode", "YES"]) == nil)
        #expect(DiskSageCLI.parse(["--help"]) == .help)
        #expect(DiskSageCLI.parse(["-v"]) == .version)
    }

    @Test func parsesScanFlagsAndRejectsInvalidOptions() {
        let parsed = DiskSageCLI.parse([
            "scan", "--json", "--risk", "low", "--category", "cache",
            "--sort", "name", "--query", "cargo", "--limit", "5"
        ])
        #expect(parsed == .scan(.init(json: true, risk: .lowRisk, category: .cache, sort: .name, query: "cargo", limit: 5)))
        #expect(DiskSageCLI.parse(["scan", "--help"]) == .help)

        for bad in [["scan", "--unknown"], ["scan", "--risk", "bogus"], ["scan", "--limit", "0"], ["scan", "--query"], ["--version", "extra"]] {
            if case .usageError = DiskSageCLI.parse(bad) {
                continue
            }
            Issue.record("Expected usageError for \(bad)")
        }
    }

    @Test func executesJSONAndTableScansWithFilteringLimitsAndWarnings() async throws {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let cargo = CleanupCandidate(
            url: home.appending(path: ".cargo/registry"),
            name: "Cargo registry cache",
            category: .cache,
            size: 2_000_000_000,
            risk: .low,
            reason: "Cargo crates",
            deletionMode: .contents
        )
        let sim = CleanupCandidate(
            url: home.appending(path: "Library/Developer/CoreSimulator/Devices/ABC"),
            name: "iPhone 16",
            category: .simulator,
            size: 5_000_000_000,
            risk: .medium,
            reason: "Shut down simulator",
            deletionMode: .simulatorDevice
        )
        let build = CleanupCandidate(
            url: home.appending(path: "Developer/app/.build"),
            name: "app/.build",
            category: .build,
            size: 500_000_000,
            risk: .low,
            reason: "Swift build output",
            deletionMode: .generatedFiles
        )
        let report = ScanReport(candidates: [sim, cargo, build], warnings: ["Limit reached in ~/Developer"])
        let fixedDate = Date(timeIntervalSince1970: 1_750_000_000)

        let jsonResult = await DiskSageCLI.run(
            .scan(.init(json: true, risk: .lowRisk, limit: 1)),
            scan: { report },
            freeSpace: { 42_000_000_000 },
            home: home,
            now: fixedDate,
            version: "1.2.3"
        )
        #expect(jsonResult.exitCode == 0)
        #expect(jsonResult.stderr.isEmpty)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiskSageCLI.ScanJSON.self, from: Data(jsonResult.stdout.utf8))
        #expect(decoded.version == "1.2.3")
        #expect(decoded.freeSpaceBytes == 42_000_000_000)
        #expect(decoded.totalScannedCount == 3)
        #expect(decoded.matchedCount == 2)
        #expect(decoded.matchedBytes == 2_500_000_000)
        #expect(decoded.warnings == ["Limit reached in ~/Developer"])
        #expect(decoded.candidates.count == 1)
        #expect(decoded.candidates[0].name == "Cargo registry cache")
        #expect(decoded.candidates[0].path == "/Users/tester/.cargo/registry")
        #expect(decoded.candidates[0].risk == "low")

        let textResult = await DiskSageCLI.run(
            .scan(.init(json: false, category: .cache)),
            scan: { report },
            freeSpace: { 42_000_000_000 },
            home: home,
            now: fixedDate,
            version: "1.2.3"
        )
        #expect(textResult.exitCode == 0)
        #expect(textResult.stdout.contains("~/.cargo/registry"))
        #expect(!textResult.stdout.contains("iPhone 16"))
        #expect(textResult.stdout.contains("1 candidate(s)"))
        #expect(textResult.stderr.contains("Warning: Limit reached in ~/Developer"))
    }

    @Test func reportsScanFailureOnStderrWithNonZeroExitCode() async {
        let failed = await DiskSageCLI.run(
            .scan(.init()),
            scan: { throw FeatureFailure(message: "Activity check unavailable") },
            freeSpace: { nil }
        )
        #expect(failed.exitCode == 1)
        #expect(failed.stdout.isEmpty)
        #expect(failed.stderr.contains("Activity check unavailable"))
    }

    @Test func parsesAndRunsExplainCommandInTextAndJSONModes() async throws {
        #expect(DiskSageCLI.parse(["explain", "/tmp/x"]) == .explain(.init(path: "/tmp/x", json: false)))
        #expect(DiskSageCLI.parse(["explain", "--json", "~/Developer/app/node_modules"]) == .explain(.init(path: "~/Developer/app/node_modules", json: true)))
        if case .usageError = DiskSageCLI.parse(["explain"]) {} else { Issue.record("Expected usageError for missing explain path") }

        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let sample = PathDiagnostic(
            path: "/Users/tester/Developer/app/node_modules",
            verdict: .skipped,
            matcher: "Project cache (Node dependencies)",
            risk: nil,
            sizeBytes: 12_000_000,
            summary: "Project cache node_modules contains tracked Git files.",
            reasons: ["Project cache node_modules contains tracked Git files."]
        )
        let text = await DiskSageCLI.run(.explain(.init(path: sample.path, json: false)), explain: { _ in sample }, home: home)
        #expect(text.exitCode == 0)
        #expect(text.stdout.contains("~/Developer/app/node_modules"))
        #expect(text.stdout.contains("Skipped"))
        #expect(text.stdout.contains("tracked Git files"))

        let json = await DiskSageCLI.run(.explain(.init(path: sample.path, json: true)), explain: { _ in sample }, home: home)
        #expect(json.exitCode == 0)
        let decoded = try JSONDecoder().decode(PathDiagnostic.self, from: Data(json.stdout.utf8))
        #expect(decoded == sample)
    }

    @Test func cliScanHonorsLimitsAbove100WithExpandedScannerCapacity() async throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        var locations: [DiskScanner.Location] = []
        for index in 0..<115 {
            let folder = f.base.appending(path: "Developer/cli-\(index)/.build", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 64).write(to: folder.appending(path: "artifact"))
            locations.append(.init(url: folder, name: "cli-\(index)/.build", category: .build,
                                   risk: .low, reason: "Fixture", deletionMode: .item))
        }
        let scanner = DiskScanner(locations: locations, activity: { .idle }, maximumCandidates: 1_000, home: f.base)
        let result = await DiskSageCLI.run(
            .scan(.init(json: true, limit: 115)),
            scan: { try await scanner.report() },
            freeSpace: { 10_000_000_000 },
            home: f.base,
            now: f.start,
            version: "0.3.0"
        )
        #expect(result.exitCode == 0)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiskSageCLI.ScanJSON.self, from: Data(result.stdout.utf8))
        #expect(decoded.totalScannedCount == 115)
        #expect(decoded.matchedCount == 115)
        #expect(decoded.candidates.count == 115)
    }
}
