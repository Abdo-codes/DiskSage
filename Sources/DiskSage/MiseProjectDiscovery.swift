import Darwin
import Foundation

/// Reads project directories from `mise`'s tracked config symlinks (`tracked-configs`).
/// Only real directories strictly inside the user's home directory are returned; global and
/// system configs are excluded.
enum MiseProjectDiscovery {
    struct Environment: Sendable {
        var home: URL
        var miseStateDir: String?
        var xdgStateHome: String?
        var miseConfigDir: String?
        var xdgConfigHome: String?
        var miseGlobalConfig: String?
        var miseSystemConfigDir: String?

        static func current(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            env: [String: String] = ProcessInfo.processInfo.environment) -> Self {
            Self(
                home: CleanupPath.fileURL(home),
                miseStateDir: env["MISE_STATE_DIR"].flatMap { $0.isEmpty ? nil : $0 },
                xdgStateHome: env["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 },
                miseConfigDir: env["MISE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 },
                xdgConfigHome: env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 },
                miseGlobalConfig: env["MISE_GLOBAL_CONFIG_FILE"].flatMap { $0.isEmpty ? nil : $0 },
                miseSystemConfigDir: env["MISE_SYSTEM_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            )
        }

        var trackedConfigsDir: URL {
            if let miseStateDir {
                return CleanupPath.fileURL(URL(fileURLWithPath: miseStateDir, isDirectory: true))
                    .appending(path: "tracked-configs", directoryHint: .isDirectory)
            }
            if let xdgStateHome {
                return CleanupPath.fileURL(URL(fileURLWithPath: xdgStateHome, isDirectory: true))
                    .appending(path: "mise/tracked-configs", directoryHint: .isDirectory)
            }
            return home.appending(path: ".local/state/mise/tracked-configs", directoryHint: .isDirectory)
        }

        var configDir: URL {
            if let miseConfigDir { return CleanupPath.fileURL(URL(fileURLWithPath: miseConfigDir, isDirectory: true)) }
            if let xdgConfigHome {
                return CleanupPath.fileURL(URL(fileURLWithPath: xdgConfigHome, isDirectory: true))
                    .appending(path: "mise", directoryHint: .isDirectory)
            }
            return home.appending(path: ".config/mise", directoryHint: .isDirectory)
        }

        func isGlobalConfig(_ file: URL) -> Bool {
            let path = CleanupPath.fileURL(file).path
            if let global = miseGlobalConfig, CleanupPath.fileURL(URL(fileURLWithPath: global)).path == path {
                return true
            }
            let systemDir = miseSystemConfigDir.map { CleanupPath.fileURL(URL(fileURLWithPath: $0)).path } ?? "/etc/mise"
            for dir in [configDir.path, systemDir] where path == dir || path.hasPrefix(dir + "/") {
                return true
            }
            return MiseProjectDiscovery.projectRoot(forConfigFile: file).path == home.path
        }
    }

    static func projectRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             env: Environment? = nil) -> [URL] {
        let environment = env ?? Environment.current(home: home)
        let dir = environment.trackedConfigsDir
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let homePath = environment.home.path

        var roots: [URL] = []
        for entry in entries {
            let linkURL = dir.appending(path: entry)
            guard let targetPath = try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path) else {
                continue
            }
            let resolvedURL: URL = targetPath.hasPrefix("/")
                ? CleanupPath.fileURL(URL(fileURLWithPath: targetPath))
                : CleanupPath.fileURL(dir.appending(path: targetPath))
            var info = stat()
            guard stat(resolvedURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            guard !environment.isGlobalConfig(resolvedURL) else { continue }

            let root = projectRoot(forConfigFile: resolvedURL)
            // Keep discovery strictly inside the user's home directory, owned by the current user.
            guard root.path.hasPrefix(homePath + "/"), TemporaryBuildOutput.isRealDirectory(root) else { continue }
            roots.append(root)
        }
        return deduplicate(roots)
    }

    /// Maps a mise config file (including `.config/mise/conf.d/*.toml`, `.mise/config.toml`, etc.)
    /// to its enclosing project directory.
    static func projectRoot(forConfigFile file: URL) -> URL {
        let clean = CleanupPath.fileURL(file)
        var dir = clean.deletingLastPathComponent()
        var base = clean.lastPathComponent
        if dir.lastPathComponent == "conf.d" && dir.deletingLastPathComponent().lastPathComponent == "mise" {
            dir = dir.deletingLastPathComponent()
            base = "config.toml"
        }
        switch dir.lastPathComponent {
        case "mise", ".mise":
            if base.hasPrefix("config") {
                dir = dir.deletingLastPathComponent()
                if dir.lastPathComponent == ".config" {
                    dir = dir.deletingLastPathComponent()
                }
            }
        case ".config":
            if base.hasPrefix("mise") {
                dir = dir.deletingLastPathComponent()
            }
        default:
            break
        }
        return CleanupPath.fileURL(dir)
    }

    /// Sorts roots and removes duplicates or roots already contained inside a shallower root.
    static func deduplicate(_ roots: [URL]) -> [URL] {
        let sorted = Set(roots.map(CleanupPath.fileURL)).sorted { $0.path < $1.path }
        var kept: [URL] = []
        for root in sorted {
            if kept.contains(where: { root.path == $0.path || root.path.hasPrefix($0.path + "/") }) {
                continue
            }
            kept.append(root)
        }
        return kept
    }
}
