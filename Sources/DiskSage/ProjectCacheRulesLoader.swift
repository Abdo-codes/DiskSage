import Darwin
import Foundation

/// Loads optional user-defined project cache rules from `$XDG_CONFIG_HOME/disksage/rules.json`
/// (or `~/.config/disksage/rules.json`) and merges them with `ProjectCacheRules.default`.
/// Custom rules can add names/markers/skip entries and adjust quiet hours (>= 1h), but can never
/// disable Git-ignore, tracked-file, nested-Git, `KeepRules`, or running-process checks.
enum ProjectCacheRulesLoader {
    private struct FileDocument: Decodable {
        var names: [String]?
        var beside: [String: [String]]?
        var refuseInside: [String: [String]]?
        var skip: [String]?
        var quietHours: Double?

        enum CodingKeys: String, CodingKey {
            case names, beside, skip
            case refuseInside = "refuse_inside"
            case quietHours = "quiet_hours"
        }
    }

    static let maximumFileBytes: off_t = 1_048_576
    static let minimumQuietHours: Double = 1

    static func configURL(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return CleanupPath.fileURL(URL(fileURLWithPath: xdg, isDirectory: true))
                .appending(path: "disksage/rules.json")
        }
        return CleanupPath.fileURL(home).appending(path: ".config/disksage/rules.json")
    }

    /// Returns merged rules for scanning/validation, falling back safely to `.default` if missing or invalid.
    static func current(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        env: [String: String] = ProcessInfo.processInfo.environment) -> ProjectCacheRules {
        let url = configURL(home: home, env: env)
        return (try? load(from: url)) ?? .default
    }

    /// Loads and validates a user rules JSON file, returning `.default` if the file does not exist.
    static func load(from url: URL) throws -> ProjectCacheRules {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return .default }
            throw FeatureFailure(message: "Could not read custom rules at \(url.path).")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_size >= 0, info.st_size <= maximumFileBytes else {
            throw FeatureFailure(message: "Custom rules file must be a regular user-owned file under 1 MiB.")
        }
        let data = try Data(contentsOf: url)
        let doc = try JSONDecoder().decode(FileDocument.self, from: data)
        return try merge(base: .default, document: doc)
    }

    private static func merge(base: ProjectCacheRules, document: FileDocument) throws -> ProjectCacheRules {
        var merged = base

        if let names = document.names {
            for name in names {
                guard ProjectCacheRules.isValidRuleName(name) else {
                    throw FeatureFailure(message: "Invalid project cache rule name: \(name)")
                }
                if !merged.names.contains(name) { merged.names.append(name) }
            }
            merged.names.sort()
        }

        if let beside = document.beside {
            for (key, markers) in beside {
                guard ProjectCacheRules.isValidRuleName(key), !markers.isEmpty,
                      markers.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\\") && $0 != "." && $0 != ".." }) else {
                    throw FeatureFailure(message: "Invalid beside rule for \(key)")
                }
                merged.beside[key] = markers
            }
        }

        if let refuseInside = document.refuseInside {
            for (key, patterns) in refuseInside {
                guard ProjectCacheRules.isValidRuleName(key),
                      patterns.allSatisfy(ProjectCacheRules.isValidInsidePattern) else {
                    throw FeatureFailure(message: "Invalid refuse_inside rule for \(key)")
                }
                merged.refuseInside[key] = patterns
            }
        }

        if let skip = document.skip {
            for name in skip {
                guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
                    throw FeatureFailure(message: "Invalid skip directory name: \(name)")
                }
                merged.skip.insert(name)
            }
        }

        if let quietHours = document.quietHours {
            guard quietHours.isFinite, quietHours >= minimumQuietHours else {
                throw FeatureFailure(message: "quiet_hours must be at least \(Int(minimumQuietHours)) hour.")
            }
            merged.quietHours = quietHours
        }

        return merged
    }
}
