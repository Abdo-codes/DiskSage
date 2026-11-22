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
}
