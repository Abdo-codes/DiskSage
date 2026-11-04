import Foundation
import Darwin

struct DiskScanner: Sendable {
    private struct Seed: Sendable {
        let url: URL
        let name: String
        let category: CandidateCategory
        let risk: RiskLevel
        let reason: String
        let deletionMode: DeletionMode
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
                reason: "Generated indexes and build products; Xcode recreates them.",
                deletionMode: .contents
            ),
            Seed(
                url: home.appending(path: "Library/Developer/Xcode/Archives", directoryHint: .isDirectory),
                name: "Xcode Archives",
                category: .archive,
                risk: .high,
                reason: "Contains shipped archives and dSYMs. Delete only when no longer needed.",
                deletionMode: .contents
            ),
            Seed(
                url: home.appending(path: "Library/Developer/CoreSimulator/Devices", directoryHint: .isDirectory),
                name: "Simulator Devices",
                category: .simulator,
                risk: .high,
                reason: "Removes installed simulator device state and app data.",
                deletionMode: .simulatorDevices
            ),
            Seed(
                url: home.appending(path: ".npm/_cacache", directoryHint: .isDirectory),
                name: "npm Package Cache",
                category: .cache,
                risk: .low,
                reason: "Downloaded npm packages; npm restores them when needed.",
                deletionMode: .item
            ),
            Seed(
                url: URL(fileURLWithPath: "/private/var/tmp/_bazel_\(NSUserName())", isDirectory: true),
                name: "Bazel Output Cache",
                category: .build,
                risk: .low,
                reason: "Generated Bazel output and repository cache.",
                deletionMode: .item
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
                    reason: "Application or command-line cache; it can be regenerated.",
                    deletionMode: .item
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
                reason: "Generated project build output. Review generic build folders before deletion.",
                deletionMode: .item
            )
        }

        var seen = Set<String>()
        return seeds.compactMap { seed in
            let url = seed.url.standardizedFileURL
            guard seen.insert(url.path).inserted,
                  fileManager.fileExists(atPath: url.path),
                  !isSymbolicLink(url),
                  !containsRunningExecutable(url),
                  let identity = fileIdentity(of: url),
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
                reason: seed.reason,
                identity: identity,
                deletionMode: seed.deletionMode
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
            if allowedNames.contains(url.lastPathComponent), isLikelyGeneratedBuildDirectory(url) {
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

    private static func isLikelyGeneratedBuildDirectory(_ url: URL) -> Bool {
        guard url.lastPathComponent == "build" else { return true }
        let projectRoot = url.deletingLastPathComponent()
        let markers = ["Package.swift", "project.yml", "build.gradle", "build.gradle.kts", "pom.xml"]
        if markers.contains(where: { FileManager.default.fileExists(atPath: projectRoot.appending(path: $0).path) }) {
            return true
        }
        guard let siblings = try? FileManager.default.contentsOfDirectory(
            at: projectRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }
        return siblings.contains { ["xcodeproj", "xcworkspace"].contains($0.pathExtension) }
    }

    private static func fileIdentity(of url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    static func allocatedSize(of root: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
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
