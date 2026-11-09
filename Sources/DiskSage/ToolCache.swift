import Foundation

/// A tool that cleans its own cache. DiskSage runs the tool's own command, so the tool
/// decides what to keep and waits for its own locks. The command comes from this list only,
/// never from a candidate.
struct ToolCache: Sendable, Equatable {
    let name: String
    let folder: URL
    /// Absolute paths, in order of preference. DiskSage never searches `PATH`.
    let executables: [String]
    let arguments: [String]
    /// A read-only run that reports what the command would free. Without it, the whole folder is the estimate.
    let estimateArguments: [String]?
    let environment: [String: String]
    let reason: String

    static func all(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ToolCache] {
        let home = CleanupPath.fileURL(home)
        let brew = home.appending(path: "Library/Caches/Homebrew", directoryHint: .isDirectory)
        let uv = home.appending(path: ".cache/uv", directoryHint: .isDirectory)
        return [
            ToolCache(name: "Homebrew downloads", folder: brew,
                      executables: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
                      arguments: ["cleanup", "-s"],
                      // `cleanup -s` keeps downloads of installed packages, so the folder size is not the estimate.
                      estimateArguments: ["cleanup", "-s", "--dry-run"],
                      environment: ["HOMEBREW_CACHE": brew.path, "HOMEBREW_NO_AUTO_UPDATE": "1",
                                    "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1",
                                    // Cleanup must never uninstall unused dependencies.
                                    "HOMEBREW_NO_AUTOREMOVE": "1"],
                      reason: "Homebrew downloads and old versions of installed packages. `brew cleanup -s` removes them; Homebrew downloads them again when needed."),
            ToolCache(name: "uv package cache", folder: uv,
                      executables: ["/opt/homebrew/bin/uv", "/usr/local/bin/uv",
                                    home.appending(path: ".local/bin/uv").path, home.appending(path: ".cargo/bin/uv").path],
                      arguments: ["cache", "clean", "--cache-dir", uv.path],
                      estimateArguments: nil,
                      environment: [:],
                      reason: "Python packages that uv downloaded. `uv cache clean` waits until no uv process uses the cache; uv downloads the packages again when needed."),
        ]
    }

    /// Reads "This operation would free approximately 1.2GB of disk space." Homebrew uses units of 1000.
    static func freedBytes(fromDryRun text: String) -> Int64 {
        guard let match = text.firstMatch(of: #/would free approximately ([0-9]+(?:\.[0-9]+)?)(B|KB|MB|GB)/#),
              let value = Double(match.1) else { return 0 }
        let scale: Double = switch match.2 { case "KB": 1e3; case "MB": 1e6; case "GB": 1e9; default: 1 }
        return Int64(value * scale)
    }

    static func matching(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ToolCache? {
        let path = CleanupPath.fileURL(url).path
        return all(home: home).first { $0.folder.path == path }
    }
}
