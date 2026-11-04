import Foundation
import Testing
@testable import DiskSage

struct CleanupParallelBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DISKSAGE_PARALLEL_BENCHMARK"] == "1"))
    func compareOneTwoAndFourWorkersOnDisposableBuildTrees() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Developer/.disksage-benchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var observations: [[String: Double]] = []
        for trial in 0..<3 {
            let order = [[1, 2, 4], [4, 1, 2], [2, 4, 1]][trial]
            for workers in order {
                let runRoot = root.appending(path: "trial-\(trial)-workers-\(workers)")
                var targets: [CleanupCandidate] = []
                for index in 0..<4 {
                    let target = runRoot.appending(path: "project\(index)/.build", directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    for folder in 0..<20 {
                        let directory = target.appending(path: "module\(folder)", directoryHint: .isDirectory)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        for file in 0..<100 {
                            try Data(repeating: 1, count: 128).write(to: directory.appending(path: "file\(file)"))
                        }
                    }
                    targets.append(try #require(DiskScanner.inspect(target, name: "Fixture", category: .build,
                                                                   risk: .low, reason: "Benchmark fixture")))
                }
                let start = ContinuousClock.now
                let report = await CleanupService(logger: CleanupLogger(directory: runRoot.appending(path: "logs")),
                    maximumWorkers: workers).delete(targets)
                let elapsed = start.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                #expect(report.loggingError == nil && report.failures.isEmpty)
                #expect(report.items.count == 4)
                #expect(report.removedEntryCount == 4 * (2_000 + 20 + 1))
                #expect(targets.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
                observations.append(["trial": Double(trial), "workers": Double(workers), "seconds": seconds])
                print("DiskSage fixture benchmark: workers=\(workers) seconds=\(seconds)")
            }
        }
        let data = try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "/tmp/disksage-parallel-benchmark.json"))
    }
}
