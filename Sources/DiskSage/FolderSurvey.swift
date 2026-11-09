import Darwin
import Foundation

/// One walk over a folder: its allocated size, its newest change, and a check
/// for Git data. The walk never follows symbolic links.
struct FolderSurvey: Sendable {
    let bytes: Int64
    let newestChange: Date

    func idle(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(newestChange)) }

    /// - Parameter gitAllowedUnder: top-level child names where Git data is expected,
    ///   such as SwiftPM clones in a DerivedData `SourcePackages` folder.
    ///   Git data anywhere else fails the survey, because it can be someone's work.
    ///   Pass nil to read only size and dates.
    static func read(_ root: URL, gitAllowedUnder: Set<String>? = [], maximumEntries: Int = 1_000_000) throws -> Self {
        let root = CleanupPath.fileURL(root)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey]
        var newest = try newestDate(of: root)
        var failed = false
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, _ in failed = true; return false }) else {
            throw FeatureFailure(message: "The folder could not be read.")
        }
        var bytes: Int64 = 0, count = 0
        for case let url as URL in walker {
            try Task.checkCancellation()
            count += 1
            guard count <= maximumEntries else { throw FeatureFailure(message: "The folder is too large to check safely.") }
            // A dangling link has no values; its own times still come from lstat below.
            let values = (try? url.resourceValues(forKeys: Set(keys))) ?? URLResourceValues()
            newest = max(newest, try newestDate(of: url))
            let parts = Array(url.pathComponents.dropFirst(root.pathComponents.count))
            if let allowed = gitAllowedUnder, isGitData(url, values: values), !(parts.first.map(allowed.contains) ?? false) {
                throw FeatureFailure(message: "The folder contains Git data. Review it with Git Worktrees instead.")
            }
            if values.isRegularFile == true { bytes += Int64(values.totalFileAllocatedSize ?? 0) }
        }
        guard !failed else { throw FeatureFailure(message: "Some files in the folder could not be read.") }
        return Self(bytes: bytes, newestChange: newest)
    }

    private static func isGitData(_ url: URL, values: URLResourceValues) -> Bool {
        if url.lastPathComponent.lowercased() == ".git" { return true }
        guard url.lastPathComponent == "HEAD", values.isRegularFile == true else { return false }
        return FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appending(path: "objects").path)
    }

    /// The latest of the content, status and birth times of the item itself (links are not followed).
    private static func newestDate(of url: URL) throws -> Date {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw FeatureFailure(message: "A change date could not be read.") }
        let seconds = [info.st_mtimespec, info.st_ctimespec, info.st_birthtimespec]
            .map { Double($0.tv_sec) + Double($0.tv_nsec) / 1e9 }.max() ?? 0
        return Date(timeIntervalSince1970: seconds)
    }
}
