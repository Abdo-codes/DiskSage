import Darwin
import Foundation

struct GeneratedBuildDiscovery {
    var maximumEntries = 200_000
    var maximumDepth = 24

    func directories(under root: URL) -> [URL] {
        let root = CleanupPath.fileURL(root)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { return [] }
        var found: [URL] = [], visited = 0
        for case let url as URL in walker {
            if Task.isCancelled { return [] }
            visited += 1
            if visited > maximumEntries { break }
            guard let values = try? url.resourceValues(forKeys: keys), values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
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
        return found
    }
}
