import Foundation

enum GeneratedCleanupScope {
    static let apps = ["Claude", "Claude-Work", "Code", "Slack", "Paper", "Spark Desktop", "Discord", "Postman"]
    static let cacheNames = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"]

    static func fixedLocations(home: URL) -> [(URL, String, GeneratedCleanupRule)] {
        var values: [(URL, String, GeneratedCleanupRule)] = [
            (home.appending(path: "Library/Developer/Xcode/DerivedData"), "Xcode generated files", .buildArtifacts),
            (URL(fileURLWithPath: "/private/var/tmp/_bazel_\(NSUserName())"), "Bazel generated files", .buildArtifacts),
            (home.appending(path: ".npm/_cacache"), "npm package downloads", .npmContent),
            (home.appending(path: ".cache/firebase-mcp-npm/_cacache"), "Firebase CLI package downloads", .npmContent),
            (home.appending(path: "Library/Caches/go-build"), "Go compiled objects", .goBuild),
            (home.appending(path: "go/pkg/mod/cache/download"), "Go package downloads", .goDownloads),
            (home.appending(path: "Library/Caches/org.swift.swiftpm/artifacts"), "SwiftPM binary downloads", .swiftPMArchives),
            (URL(fileURLWithPath: "/private/var/tmp/_bazel_\(NSUserName())/cache/repos/v1/content_addressable/sha256"),
             "Bazel repository downloads", .bazelArchives)
        ]
        for app in apps {
            var names = cacheNames
            if app == "Code" { names += ["CachedData", "CachedExtensionVSIXs"] }
            for name in names {
                values.append((home.appending(path: "Library/Application Support/\(app)/\(name)"), "\(app) · \(name)", .browserCache))
            }
        }
        return values.map { (CleanupPath.fileURL($0.0), $0.1, $0.2) }
    }

    static func discoveryRoots(home: URL) -> [URL] {
        [home.appending(path: "Developer"), home.appending(path: "Documents/Codex"),
         home.appending(path: ".codex/visualizations"), URL(fileURLWithPath: "/private/tmp"),
         URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/agent-device/apple/macos-helper")]
            .map(CleanupPath.fileURL)
    }

    static func rule(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> GeneratedCleanupRule? {
        let root = CleanupPath.fileURL(url), home = CleanupPath.fileURL(home)
        if let fixed = fixedLocations(home: home).first(where: { $0.0 == root }) { return fixed.2 }
        guard !root.pathComponents.contains(where: GeneratedCleanupPolicy.protected),
              discoveryRoots(home: home).contains(where: { root.path.hasPrefix($0.path + "/") }),
              isBuildDirectory(root) else { return nil }
        return .buildArtifacts
    }

    static func isBuildDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if GeneratedCleanupPolicy.compilerCaches.contains(name) || name == ".build" || name.hasPrefix(".build-") ||
            ["DerivedData", "derived-data"].contains(name) { return true }
        // Ad-hoc derived-data names are accepted only with a real Xcode output marker.
        let markers = ["Build/Intermediates.noindex", "Build/Products", "SDKExplicitPrecompiledModules"]
        return markers.contains { marker in
            let path = url.appending(path: marker)
            let values = try? path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
    }
}
