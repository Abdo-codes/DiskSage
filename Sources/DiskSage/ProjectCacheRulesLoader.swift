import Darwin
import Foundation

/// Loads and saves optional user-defined project cache rules from `$XDG_CONFIG_HOME/disksage/rules.json`
/// (or `~/.config/disksage/rules.json`) and merges them with `ProjectCacheRules.default`.
/// Custom rules can add names/markers/skip entries, add extra project roots under `$HOME`, and
/// adjust quiet hours (>= 1h), but can never disable Git-ignore, tracked-file, nested-Git,
/// `KeepRules`, or running-process checks.
enum ProjectCacheRulesLoader {
    struct UserConfig: Codable, Equatable, Sendable {
        var names: [String]?
        var beside: [String: [String]]?
        var refuseInside: [String: [String]]?
        var skip: [String]?
        var quietHours: Double?
        var extraRoots: [String]?

        enum CodingKeys: String, CodingKey {
            case names, beside, skip
            case refuseInside = "refuse_inside"
            case quietHours = "quiet_hours"
            case extraRoots = "extra_roots"
        }

        var isEmpty: Bool {
            (names ?? []).isEmpty && (beside ?? [:]).isEmpty && (refuseInside ?? [:]).isEmpty
                && (skip ?? []).isEmpty && quietHours == nil && (extraRoots ?? []).isEmpty
        }
    }

    static let maximumFileBytes: off_t = 1_048_576
    static let minimumQuietHours: Double = 1
    static let editableQuietHoursRange: ClosedRange<Int> = 1...168

    /// Validates that `quiet_hours` fits safely inside the Settings UI's integer stepper range without trapping.
    static func editableQuietHours(from config: UserConfig) throws -> Int {
        guard let raw = config.quietHours else { return Int(ProjectCacheRules.default.quietHours) }
        let minValue = Double(editableQuietHoursRange.lowerBound)
        let maxValue = Double(editableQuietHoursRange.upperBound)
        guard raw.isFinite, raw >= minValue, raw <= maxValue, raw.rounded() == raw else {
            throw FeatureFailure(
                message: "quiet_hours (\(raw)) is outside the Settings UI range (\(editableQuietHoursRange.lowerBound)–\(editableQuietHoursRange.upperBound) whole hours). Edit rules.json directly."
            )
        }
        return Int(raw)
    }

    /// Formats an array of rule entries as one entry per line, failing if any entry cannot round-trip losslessly.
    static func editableLines(from entries: [String]?, field: String) throws -> String {
        guard let entries else { return "" }
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty,
                  trimmed == entry,
                  !entry.contains(where: \.isNewline) else {
                throw FeatureFailure(
                    message: "\(field) contains entries that cannot be edited line-by-line safely. Edit rules.json directly."
                )
            }
        }
        return entries.joined(separator: "\n")
    }

    static func parseLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func configURL(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          env: [String: String]? = nil) -> URL {
        let canonicalHome = CleanupPath.fileURL(home)
        let effectiveEnv = env ?? (canonicalHome == CleanupPath.fileURL(FileManager.default.homeDirectoryForCurrentUser)
            ? ProcessInfo.processInfo.environment : [:])
        if let xdg = effectiveEnv["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return CleanupPath.fileURL(URL(fileURLWithPath: xdg, isDirectory: true))
                .appending(path: "disksage/rules.json")
        }
        return canonicalHome.appending(path: ".config/disksage/rules.json")
    }

    /// Returns merged rules for scanning/validation, falling back safely to `.default` if missing or invalid.
    static func current(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        env: [String: String]? = nil) -> ProjectCacheRules {
        let url = configURL(home: home, env: env)
        return (try? load(from: url)) ?? .default
    }

    /// Returns validated, existing extra project roots from `rules.json`, ignoring any individual invalid entry.
    static func extraRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           env: [String: String]? = nil) -> [URL] {
        let url = configURL(home: home, env: env)
        guard let config = try? loadConfig(from: url) else { return [] }
        let valid = (config.extraRoots ?? [])
            .compactMap { validatedExtraRoot($0, home: home) }
            .filter { TemporaryBuildOutput.isRealDirectory($0) }
        return MiseProjectDiscovery.uniqueSorted(valid)
    }

    /// Reads the raw user configuration document, returning an empty `UserConfig` when absent.
    static func loadConfig(from url: URL) throws -> UserConfig {
        try rejectSymlinkedAncestors(of: url)
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return UserConfig() }
            throw FeatureFailure(message: "Could not read custom rules at \(url.path).")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_size >= 0, info.st_size <= maximumFileBytes else {
            throw FeatureFailure(message: "Custom rules file must be a regular user-owned file under 1 MiB.")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(UserConfig.self, from: data)
    }

    /// Loads and validates a user rules JSON file, returning `.default` if the file does not exist.
    static func load(from url: URL) throws -> ProjectCacheRules {
        let doc = try loadConfig(from: url)
        return try merge(base: .default, document: doc)
    }

    /// Validates and atomically writes `config` to `url` with `0o600` permissions, refusing symlinks.
    static func save(_ config: UserConfig, to url: URL = configURL(),
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        _ = try merge(base: .default, document: config)
        _ = try validatedExtraRoots(config.extraRoots ?? [], home: home)
        let data = try encode(config)
        try rejectSymlinkedAncestors(of: url)

        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG, existing.st_uid == getuid() else {
                throw FeatureFailure(message: "Refused to overwrite non-regular or non-user-owned rules file.")
            }
        } else if errno != ENOENT {
            throw FeatureFailure(message: "Could not inspect custom rules path.")
        }

        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try rejectSymlinkedAncestors(of: url)

        let temp = parent.appending(path: ".rules-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw FeatureFailure(message: "Could not write temporary custom rules file.")
        }
        if Darwin.rename(temp.path, url.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw FeatureFailure(message: "Could not save custom rules: \(String(cString: strerror(code))).")
        }
    }

    private static func encode(_ config: UserConfig) throws -> Data {
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try pretty.encode(config) + Data("\n".utf8)
        if Int64(data.count) > Int64(maximumFileBytes) {
            let compact = JSONEncoder()
            compact.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data = try compact.encode(config) + Data("\n".utf8)
        }
        guard Int64(data.count) <= Int64(maximumFileBytes) else {
            throw FeatureFailure(message: "Custom rules exceed the 1 MiB file size limit.")
        }
        return data
    }

    static func invalidExtraRoots(_ entries: [String],
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        entries.filter { validatedExtraRoot($0, home: home) == nil }
    }

    static func validatedExtraRoots(_ entries: [String],
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [URL] {
        var resolved: [URL] = []
        for entry in entries {
            guard let url = validatedExtraRoot(entry, home: home) else {
                throw FeatureFailure(message: "Extra project root must be a non-symlinked folder under ~ (not ~/Library): \(entry)")
            }
            resolved.append(url)
        }
        return MiseProjectDiscovery.uniqueSorted(resolved)
    }

    static func isValidSkipName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && name != "." && name != ".."
    }

    private static func validatedExtraRoot(_ raw: String, home: URL) -> URL? {
        let canonicalHome = CleanupPath.fileURL(home)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = trimmed.hasPrefix("~/") ? canonicalHome.path + trimmed.dropFirst(1) : trimmed
        guard expanded.hasPrefix("/") else { return nil }

        let standardizedPath = normalizeSystemPrefix(URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path)
        let standardized = URL(fileURLWithPath: standardizedPath, isDirectory: true)
        guard standardized.path.hasPrefix(canonicalHome.path + "/"),
              !standardized.pathComponents.contains(".git") else { return nil }

        let library = canonicalHome.appending(path: "Library", directoryHint: .isDirectory).path
            .precomposedStringWithCanonicalMapping.lowercased()
        let loweredPath = standardized.path.precomposedStringWithCanonicalMapping.lowercased()
        guard loweredPath != library, !loweredPath.hasPrefix(library + "/") else { return nil }

        guard (try? rejectSymlinkedAncestors(of: standardized)) != nil else { return nil }
        var info = stat()
        if lstat(standardized.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        }
        return CleanupPath.fileURL(standardized)
    }

    private static func normalizeSystemPrefix(_ path: String) -> String {
        for prefix in ["/var", "/tmp", "/etc"] where path == prefix || path.hasPrefix(prefix + "/") {
            return "/private" + path
        }
        return path
    }

    private static func rejectSymlinkedAncestors(of url: URL) throws {
        let normalized = URL(fileURLWithPath: normalizeSystemPrefix(url.standardizedFileURL.path))
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in normalized.pathComponents.dropFirst() {
            current.append(path: component)
            var info = stat()
            guard lstat(current.path, &info) == 0 else {
                if errno == ENOENT { return }
                throw FeatureFailure(message: "Unable to verify path component \(current.path).")
            }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                throw FeatureFailure(message: "Symlinked path components are not allowed: \(current.path)")
            }
        }
    }

    private static func merge(base: ProjectCacheRules, document: UserConfig) throws -> ProjectCacheRules {
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
                // Always preserve built-in protections; custom patterns extend them.
                var combined = merged.refuseInside[key] ?? []
                for pattern in patterns where !combined.contains(pattern) {
                    combined.append(pattern)
                }
                merged.refuseInside[key] = combined
            }
        }

        if let skip = document.skip {
            for name in skip {
                guard isValidSkipName(name) else {
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
