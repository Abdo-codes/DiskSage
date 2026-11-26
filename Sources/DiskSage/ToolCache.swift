import Foundation

/// A tool that cleans its own cache. DiskSage runs the tool's own command from the home
/// directory without a shell, so the tool decides what to keep and project configs do not apply.
/// Commands come from this allowlist only, never from a candidate.
struct ToolCache: Sendable, Equatable {
    /// A read-only check that must pass before offering or running the cleanup command.
    struct PreflightCheck: Sendable, Equatable {
        let arguments: [String]
        let requirePattern: String?
        let refusePattern: String?
        let refusalReason: String

        /// Returns nil when the output satisfies the check, or a user-facing reason when it fails.
        func evaluate(code: Int32, text: String) -> String? {
            guard code == 0 else { return refusalReason }
            let cleaned = text.replacingOccurrences(of: #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            let lines = cleaned.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let requirePattern {
                let matches = lines.filter { $0.range(of: requirePattern, options: .regularExpression) != nil }
                guard matches.count == 1 else { return refusalReason }
            }
            if let refusePattern, lines.contains(where: { $0.range(of: refusePattern, options: .regularExpression) != nil }) {
                return refusalReason
            }
            return nil
        }
    }

    let name: String
    let folder: URL
    /// Absolute paths, in order of preference. DiskSage never searches `PATH`.
    let executables: [String]
    let arguments: [String]
    /// A read-only run that reports what the command would free. Without it, the whole folder is the estimate.
    let estimateArguments: [String]?
    let environment: [String: String]
    let preflightChecks: [PreflightCheck]
    /// True for Node-based tools (such as Corepack shims for pnpm/Yarn) that invoke `#!/usr/bin/env node`.
    let needsNodeRuntime: Bool
    let reason: String

    static func all(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ToolCache] {
        let home = CleanupPath.fileURL(home)
        let brew = home.appending(path: "Library/Caches/Homebrew", directoryHint: .isDirectory)
        let uv = home.appending(path: ".cache/uv", directoryHint: .isDirectory)
        let mise = home.appending(path: "Library/Caches/mise", directoryHint: .isDirectory)
        let pnpm = home.appending(path: "Library/pnpm/store", directoryHint: .isDirectory)
        let pip = home.appending(path: "Library/Caches/pip", directoryHint: .isDirectory)
        let bun = home.appending(path: ".bun/install/cache", directoryHint: .isDirectory)
        let yarn = home.appending(path: "Library/Caches/Yarn", directoryHint: .isDirectory)
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
                      preflightChecks: [],
                      needsNodeRuntime: false,
                      reason: "Homebrew downloads and old versions of installed packages. `brew cleanup -s` removes them; Homebrew downloads them again when needed."),
            ToolCache(name: "uv package cache", folder: uv,
                      executables: ["/opt/homebrew/bin/uv", "/usr/local/bin/uv",
                                    home.appending(path: ".local/bin/uv").path, home.appending(path: ".cargo/bin/uv").path,
                                    home.appending(path: ".local/share/mise/shims/uv").path],
                      arguments: ["cache", "clean", "--cache-dir", uv.path],
                      estimateArguments: nil,
                      environment: [:],
                      preflightChecks: [],
                      needsNodeRuntime: false,
                      reason: "Python packages that uv downloaded. `uv cache clean` waits until no uv process uses the cache; uv downloads the packages again when needed."),
            ToolCache(name: "mise download cache", folder: mise,
                      executables: ["/opt/homebrew/bin/mise", "/usr/local/bin/mise",
                                    home.appending(path: ".local/bin/mise").path, home.appending(path: ".cargo/bin/mise").path],
                      arguments: ["cache", "prune"],
                      // `mise cache prune` only removes files not accessed within `cache_prune_age`, so estimate via `--dry-run`.
                      estimateArguments: ["cache", "prune", "--dry-run"],
                      environment: ["MISE_CACHE_DIR": mise.path],
                      preflightChecks: [],
                      needsNodeRuntime: false,
                      reason: "Stale download archives cached by mise. `mise cache prune` removes unused archives and keeps installed tool versions."),
            ToolCache(name: "pnpm package store", folder: pnpm,
                      executables: ["/opt/homebrew/bin/pnpm", "/usr/local/bin/pnpm",
                                    home.appending(path: "Library/pnpm/pnpm").path,
                                    home.appending(path: ".local/share/pnpm/pnpm").path,
                                    home.appending(path: ".volta/bin/pnpm").path,
                                    home.appending(path: ".local/share/mise/shims/pnpm").path],
                      arguments: ["store", "prune"],
                      estimateArguments: nil,
                      environment: ["npm_config_store_dir": pnpm.path],
                      preflightChecks: [],
                      needsNodeRuntime: true,
                      reason: "Unreferenced packages in the pnpm store. `pnpm store prune` removes only unused packages; projects keep their dependencies."),
            ToolCache(name: "pip package cache", folder: pip,
                      executables: ["/opt/homebrew/bin/pip3", "/usr/local/bin/pip3", "/usr/bin/pip3"],
                      arguments: ["cache", "purge"],
                      estimateArguments: nil,
                      environment: ["PIP_CACHE_DIR": pip.path],
                      preflightChecks: [],
                      needsNodeRuntime: false,
                      reason: "Python wheels and source archives cached by pip. `pip3 cache purge` removes them; pip downloads packages again when needed."),
            ToolCache(name: "Bun package cache", folder: bun,
                      executables: [home.appending(path: ".bun/bin/bun").path,
                                    "/opt/homebrew/bin/bun", "/usr/local/bin/bun",
                                    home.appending(path: ".local/share/mise/shims/bun").path],
                      arguments: ["pm", "cache", "prune"],
                      estimateArguments: nil,
                      environment: ["BUN_INSTALL_CACHE_DIR": bun.path],
                      // Bun added `pm cache prune` in 1.4.4; older versions have no safe prune subcommand.
                      preflightChecks: [PreflightCheck(
                          arguments: ["--version"],
                          requirePattern: #"^[0-9]+\.[0-9]+\.[0-9]+"#,
                          refusePattern: #"^(0\.|1\.[0-3]\.|1\.4\.[0-3]([^0-9]|$))"#,
                          refusalReason: "Bun before 1.4.4 does not support `bun pm cache prune`.")],
                      needsNodeRuntime: false,
                      reason: "Older package folders cached by Bun. `bun pm cache prune` removes stale packages while keeping global store links."),
            ToolCache(name: "Yarn 1 package cache", folder: yarn,
                      executables: ["/opt/homebrew/bin/yarn", "/usr/local/bin/yarn",
                                    home.appending(path: ".volta/bin/yarn").path,
                                    home.appending(path: ".local/share/mise/shims/yarn").path],
                      arguments: ["cache", "clean", "--cache-folder", yarn.path],
                      estimateArguments: nil,
                      environment: [:],
                      // Yarn 2+ can store zero-install caches inside Git repositories, so only Yarn 1 uses this folder.
                      preflightChecks: [PreflightCheck(
                          arguments: ["--version"],
                          requirePattern: #"^[0-9]+\.[0-9]+\.[0-9]+"#,
                          refusePattern: #"^(0|[2-9]|[1-9][0-9]+)\.[0-9]+\.[0-9]+"#,
                          refusalReason: "Only Yarn 1 uses this global cache folder.")],
                      needsNodeRuntime: true,
                      reason: "Node packages cached by Yarn 1. `yarn cache clean` removes them; Yarn downloads packages again when needed."),
        ]
    }

    /// Trusted directories that may hold a `node` binary for Node-based tool launchers.
    static func trustedNodeCandidates(home: URL, executable: String) -> [String] {
        let home = CleanupPath.fileURL(home)
        let execDir = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        var dirs = [execDir, "/opt/homebrew/bin", "/usr/local/bin", home.appending(path: ".volta/bin").path]
        if let resolved = realpath(executable, nil) {
            let resolvedDir = URL(fileURLWithPath: String(cString: resolved)).deletingLastPathComponent().path
            free(resolved)
            dirs.insert(resolvedDir, at: 1)
        }
        dirs.append(home.appending(path: ".local/share/mise/shims").path)
        dirs.append(home.appending(path: ".local/share/mise/installs/node/latest/bin").path)
        dirs.append(home.appending(path: ".local/share/mise/installs/node/lts/bin").path)
        dirs += versionedNodeBinDirectories(under: home.appending(path: ".local/share/mise/installs/node"))
        dirs += versionedNodeBinDirectories(under: home.appending(path: ".nvm/versions/node"))
        dirs.append(home.appending(path: "Library/Application Support/fnm/aliases/default/bin").path)
        dirs.append(home.appending(path: ".local/share/fnm/aliases/default/bin").path)
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }.map { $0 + "/node" }
    }

    private static func versionedNodeBinDirectories(under root: URL) -> [String] {
        guard TemporaryBuildOutput.isRealDirectory(root),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        let parsed: [(major: Int, minor: Int, patch: Int, name: String, binPath: String)] = names.compactMap { name in
            let child = root.appending(path: name, directoryHint: .isDirectory)
            guard TemporaryBuildOutput.isRealDirectory(child),
                  let version = parseSemverTuple(name) else { return nil }
            return (version.major, version.minor, version.patch, name, child.appending(path: "bin").path)
        }
        return parsed.sorted { lhs, rhs in
            if lhs.major != rhs.major { return lhs.major > rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor > rhs.minor }
            if lhs.patch != rhs.patch { return lhs.patch > rhs.patch }
            return lhs.name > rhs.name
        }.map(\.binPath)
    }

    private static func parseSemverTuple(_ name: String) -> (major: Int, minor: Int, patch: Int)? {
        let stripped = (name.hasPrefix("v") || name.hasPrefix("V")) ? String(name.dropFirst()) : name
        let parts = stripped.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]) else { return nil }
        let minor = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        let patch = parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
        return (major, minor, patch)
    }

    /// Reads dry-run summaries from Homebrew ("would free approximately 1.2GB")
    /// and mise ("mise cache pruned 3 files, 24.5 MiB").
    static func freedBytes(fromDryRun text: String) -> Int64 {
        let cleaned = text.replacingOccurrences(of: #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        if let match = cleaned.firstMatch(of: #/would free approximately ([0-9]+(?:\.[0-9]+)?)(B|KB|MB|GB|TB)/#),
           let value = Double(match.1) {
            return scaledBytes(value, unit: String(match.2))
        }
        if let match = cleaned.firstMatch(of: #/mise cache pruned [0-9]+ files?, ([0-9]+(?:\.[0-9]+)?)\s*(B|KiB|MiB|GiB|TiB|KB|MB|GB|TB)/#),
           let value = Double(match.1) {
            return scaledBytes(value, unit: String(match.2))
        }
        return 0
    }

    private static func scaledBytes(_ value: Double, unit: String) -> Int64 {
        let scale: Double = switch unit {
        case "KiB": 1_024
        case "MiB": 1_048_576
        case "GiB": 1_073_741_824
        case "TiB": 1_099_511_627_776
        case "KB": 1e3
        case "MB": 1e6
        case "GB": 1e9
        case "TB": 1e12
        default: 1
        }
        return Int64(value * scale)
    }

    static func matching(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ToolCache? {
        let path = CleanupPath.fileURL(url).path
        return all(home: home).first { $0.folder.path == path }
    }
}
