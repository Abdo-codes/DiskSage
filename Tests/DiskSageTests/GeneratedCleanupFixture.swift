import Foundation
@testable import DiskSage

struct GeneratedCleanupFixture {
    let home: URL
    let root: URL
    let now = Date().addingTimeInterval(7_200)
    var policy: SafetyPolicy { SafetyPolicy(home: home, now: now) }
    var cutoff: Date { now.addingTimeInterval(-3_600) }
    init(relative: String = "Developer/Project/.build") throws {
        home = URL(fileURLWithPath: "/private/tmp/DS-generated-\(UUID())", isDirectory: true)
        root = home.appending(path: relative)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    @discardableResult func write(_ path: String, data: Data = Data(repeating: 42, count: 4_096)) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appending(path: path).path) }
    func candidate(rule: GeneratedCleanupRule = .buildArtifacts) throws -> CleanupCandidate? {
        try GeneratedFileDeleter.inspect(root, name: "Fixture", category: .build, rule: rule,
            activity: .idle, cutoff: cutoff, policy: policy)
    }
    func delete(_ target: CleanupCandidate, before: (Int) throws -> Void = { _ in }) throws {
        try GeneratedFileDeleter.delete(target, policy: policy, activity: { .idle }, beforeEntry: before, entryRemoved: {})
    }
    func remove() { try? FileManager.default.removeItem(at: home) }
}
