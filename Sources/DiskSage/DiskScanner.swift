import Foundation

struct DiskScanner: Sendable {
    private struct Seed: Sendable {
        let url: URL
        let name: String
        let category: CandidateCategory
        let risk: RiskLevel
        let reason: String
    }

    func scan() async -> [CleanupCandidate] {
        await Task.detached(priority: .utility) {
            Self.scanSynchronously()
        }.value
    }

    private static func scanSynchronously() -> [CleanupCandidate] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        let developer = home.appending(path: "Developer", directoryHint: .isDirectory)

        var seeds: [Seed] = [
            Seed(
                url: home.appending(path: "Library/Developer/Xcode/DerivedData", directoryHint: .isDirectory),
                name: "Xcode DerivedData",
                category: .build,
                risk: .low,
                reason: "Generated indexes and build products; Xcode recreates them."
            ),
            Seed(
                url: home.appending(path: "Library/Developer/Xcode/Archives", directoryHint: .isDirectory),
                name: "Xcode Archives",
                category: .archive,
                risk: .high,
                reason: "Contains shipped archives and dSYMs. Delete only when no longer needed."
            ),
            Seed(
                url: home.appending(path: "Library/Developer/CoreSimulator/Devices", directoryHint: .isDirectory),
                name: "Simulator Devices",
                category: .simulator,
                risk: .high,
                reason: "Removes installed simulator device state and app data."
            ),
            Seed(
                url: home.appending(path: ".npm/_cacache", directoryHint: .isDirectory),
                name: "npm Package Cache",
                category: .cache,
                risk: .low,
                reason: "Downloaded npm packages; npm restores them when needed."
            ),
            Seed(
                url: URL(fileURLWithPath: "/private/var/tmp/_bazel_\(NSUserName())", isDirectory: true),
                name: "Bazel Output Cache",
                category: .build,
                risk: .low,
                reason: "Generated Bazel output and repository cache."
            )
        ]

        let cacheRoots = [
            home.appending(path: "Library/Caches", directoryHint: .isDirectory),
            home.appending(path: ".cache", directoryHint: .isDirectory)
        ]
        for root in cacheRoots {
            seeds += childDirectories(of: root).map { child in
                Seed(
                    url: child,
                    name: child.lastPathComponent,
                    category: .cache,
                    risk: .low,
                    reason: "Application or command-line cache; it can be regenerated."
                )
            }
        }

        seeds += buildDirectories(under: developer).map { url in
            let relative = url.path.replacingOccurrences(of: developer.path + "/", with: "")
            return Seed(
                url: url,
                name: relative,
                category: .build,
                risk: url.lastPathComponent == "build" ? .medium : .low,
                reason: "Generated project build output. Review generic build folders before deletion."
            )
        }

        var seen = Set<String>()
        return seeds.compactMap { seed in
            let url = seed.url.standardizedFileURL
            guard seen.insert(url.path).inserted,
                  fileManager.fileExists(atPath: url.path),
                  !isSymbolicLink(url),
                  !containsRunningExecutable(url),
                  let size = allocatedSize(of: url),
                  size > 0 else {
                return nil
            }
            return CleanupCandidate(
                url: url,
                name: seed.name,
                category: seed.category,
                size: size,
                risk: seed.risk,
                reason: seed.reason
            )
        }
        .sorted { $0.size > $1.size }
        .prefix(100)
        .map { $0 }
    }

    private static func childDirectories(of root: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return [] }

        return children.filter { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    private static func buildDirectories(under root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - root.pathComponents.count
            if depth > 4 {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }

            let allowedNames = [".build", "build", "DerivedData", "derived-data"]
            if allowedNames.contains(url.lastPathComponent) {
                results.append(url)
                enumerator.skipDescendants()
            }
        }
        return results
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func containsRunningExecutable(_ url: URL) -> Bool {
        guard let executable = Bundle.main.executableURL?.standardizedFileURL else { return false }
        return executable.path.hasPrefix(url.path + "/")
    }

    private static func allocatedSize(of root: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            let values = try? root.resourceValues(forKeys: keys)
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
