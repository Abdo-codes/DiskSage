import Darwin
import Foundation

struct GeneratedBuildDiscovery {
    /// Bounds the walk time. Every visited file and folder counts.
    var maximumEntries = 5_000_000
    /// Bounds the walk size. Only folders count, so many plain files cannot stop the search early.
    var maximumDirectories = 500_000
    var maximumDepth = 24

    func directories(under root: URL) -> [URL] { discover(under: root).directories }

    /// `limitReached` is true when a limit stopped the walk. Build folders after that point were not found.
    func discover(under root: URL) -> (directories: [URL], limitReached: Bool) {
        let root = CleanupPath.fileURL(root)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { return ([], false) }
        var found: [URL] = [], visited = 0, folders = 0
        for case let url as URL in walker {
            if Task.isCancelled { return ([], false) }
            visited += 1
            if visited > maximumEntries { return (found, true) }
            guard let values = try? url.resourceValues(forKeys: keys), values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            folders += 1
            if folders > maximumDirectories { return (found, true) }
            let parts = url.pathComponents.dropFirst(root.pathComponents.count)
            if parts.count > maximumDepth || parts.contains(where: GeneratedCleanupPolicy.protected) {
                walker.skipDescendants()
                continue
            }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == getuid() else {
                walker.skipDescendants()
                continue
            }
            if GeneratedCleanupScope.isBuildDirectory(url) {
                found.append(CleanupPath.fileURL(url))
                walker.skipDescendants()
            }
        }
        return (found, false)
    }
}
