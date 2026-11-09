import Foundation

/// Finds folders that coding agents leave behind: Codex day folders, build output at the top of
/// the Claude and temporary folders, and result bundles in Codex task folders. It also lists the
/// Xcode folders that are offered whole: DerivedData projects and device symbols.
/// It only lists folders. `TemporaryBuildOutput.kind` decides what each one is, and
/// `TemporaryBuildInspector` checks age, activity and Git data.
enum AgentWorkspaceDiscovery {
    static func folders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let home = CleanupPath.fileURL(home)
        let found = codexDays(home: home) + topLevel() + taskBundles(home: home) +
            children(TemporaryBuildOutput.xcodeDerivedData(home: home)) +
            DeviceSupportVersion.roots(home: home).flatMap(children)
        return found.filter { TemporaryBuildOutput.kind(of: $0, home: home) != nil }
    }

    /// `~/.codex/{visualizations,sessions}/<yyyy>/<mm>/<dd>`.
    static func codexDays(home: URL) -> [URL] {
        ["visualizations", "sessions"].flatMap { name -> [URL] in
            var level = [TemporaryBuildOutput.codexRoot(name, home: home)]
            for _ in 0..<3 { level = level.flatMap(children) }
            return level
        }
    }

    /// Direct children of /private/tmp and of the Claude folder. Claude project folders
    /// (their names start with "-") hold sessions, which the scratchpad rule covers.
    static func topLevel(temporaryRoot: URL = TemporaryBuildOutput.temporaryRoot,
                         claudeRoot: URL = TemporaryBuildOutput.claudeRoot) -> [URL] {
        let claude = CleanupPath.fileURL(claudeRoot).path
        let tmp = children(temporaryRoot).filter { CleanupPath.fileURL($0).path != claude }
        return tmp + children(claudeRoot).filter { !$0.lastPathComponent.hasPrefix("-") }
    }

    /// `.xcresult` and `.app` bundles in `~/Documents/Codex`, at most six folders down.
    /// The walk does not go into bundles, archives or Git data.
    static func taskBundles(home: URL, maximumFolders: Int = 20_000) -> [URL] {
        let root = TemporaryBuildOutput.derivedDataRoots(home: home)[1]
        let skipped: Set<String> = [".git", "node_modules", ".build", "deriveddata", "sourcepackages"]
        var result: [URL] = [], level = [root], visited = 0
        for _ in 0..<6 {
            var next: [URL] = []
            for folder in level {
                // Source trees can be large: stop early rather than slow the scan.
                visited += 1
                guard visited <= maximumFolders, !Task.isCancelled else { return result }
                for child in children(folder) {
                    let name = child.lastPathComponent.lowercased()
                    if name.hasSuffix(".xcresult") || name.hasSuffix(".app") { result.append(child) }
                    else if !name.hasSuffix(".xcarchive"), !name.hasSuffix(".dsym"), !skipped.contains(name) { next.append(child) }
                }
            }
            level = next
        }
        return result
    }

    /// Real subfolders that the current user owns. Links are never followed.
    private static func children(_ folder: URL) -> [URL] {
        guard TemporaryBuildOutput.isRealDirectory(folder),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.sorted().map { CleanupPath.fileURL(folder.appending(path: $0, directoryHint: .isDirectory)) }
            .filter(TemporaryBuildOutput.isRealDirectory)
    }
}
