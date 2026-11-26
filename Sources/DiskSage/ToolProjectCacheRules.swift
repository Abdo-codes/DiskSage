import Darwin
import Foundation

/// Validation, patch application, and read snapshots for exposing `~/.config/disksage/rules.json`
/// through MCP while enforcing DiskSage's human-approval requirement on writes.
enum ToolProjectCacheRules {
    static var patchSchema: [String: [String: Any]] {
        [
            "quiet_hours": MCPManagementSchema.integer(
                ProjectCacheRulesLoader.editableQuietHoursRange.lowerBound,
                ProjectCacheRulesLoader.editableQuietHoursRange.upperBound
            ),
            "extra_roots": ["type": "array", "items": MCPManagementSchema.text, "maxItems": 50],
            "names": ["type": "array", "items": MCPManagementSchema.text, "maxItems": 100],
            "skip": ["type": "array", "items": MCPManagementSchema.text, "maxItems": 100],
            "reset": MCPManagementSchema.boolean,
        ]
    }

    static func applyPatch(
        _ patch: [String: ToolValue],
        to existing: ProjectCacheRulesLoader.UserConfig,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> ProjectCacheRulesLoader.UserConfig {
        guard !patch.isEmpty else {
            throw FeatureFailure(message: "Supply at least one project cache rule change.")
        }
        if let reset = patch["reset"]?.bool {
            if reset {
                guard patch.count == 1 else {
                    throw FeatureFailure(message: "reset cannot be combined with other project cache rule fields.")
                }
                var updated = existing
                updated.quietHours = nil
                updated.extraRoots = nil
                updated.names = nil
                updated.skip = nil
                _ = try ProjectCacheRulesLoader.merge(base: .default, document: updated)
                return updated
            }
            guard patch.count > 1 else {
                throw FeatureFailure(message: "Supply at least one project cache rule change.")
            }
        }

        var updated = existing
        if let hoursValue = patch["quiet_hours"] {
            guard let hours = hoursValue.integer,
                  ProjectCacheRulesLoader.editableQuietHoursRange.contains(hours) else {
                let range = ProjectCacheRulesLoader.editableQuietHoursRange
                throw FeatureFailure(message: "quiet_hours must be an integer between \(range.lowerBound) and \(range.upperBound).")
            }
            updated.quietHours = Double(hours) == ProjectCacheRules.default.quietHours ? nil : Double(hours)
        }

        if let rootsValue = patch["extra_roots"] {
            let roots = try validatedLineEntries(rootsValue, field: "extra_roots")
            _ = try ProjectCacheRulesLoader.validatedExtraRoots(roots, home: home)
            updated.extraRoots = roots.isEmpty ? nil : roots
        }

        if let namesValue = patch["names"] {
            let names = try validatedLineEntries(namesValue, field: "names")
            for name in names where !ProjectCacheRules.isValidRuleName(name) {
                throw FeatureFailure(message: "Invalid project cache rule name: \(name)")
            }
            updated.names = names.isEmpty ? nil : names
        }

        if let skipValue = patch["skip"] {
            let skip = try validatedLineEntries(skipValue, field: "skip")
            for name in skip where !ProjectCacheRulesLoader.isValidSkipName(name) {
                throw FeatureFailure(message: "Invalid skip directory name: \(name)")
            }
            updated.skip = skip.isEmpty ? nil : skip
        }

        _ = try ProjectCacheRulesLoader.merge(base: .default, document: updated)
        return updated
    }

    static func details(
        _ patch: [String: ToolValue],
        updated: ProjectCacheRulesLoader.UserConfig,
        configPath: String
    ) -> String {
        var lines = ["Config file: \(configPath)"]
        if patch["reset"]?.bool == true {
            lines.append("Reset custom quiet hours, extra project roots, extra names, and extra skip folders to defaults.")
            if let beside = updated.beside, !beside.isEmpty {
                lines.append("Custom beside markers stay preserved.")
            }
            if let refuse = updated.refuseInside, !refuse.isEmpty {
                lines.append("Custom refuse_inside protections stay preserved.")
            }
            return lines.joined(separator: "\n")
        }
        for key in patch.keys.sorted() where key != "reset" {
            switch key {
            case "quiet_hours":
                let hours = Int(updated.quietHours ?? ProjectCacheRules.default.quietHours)
                lines.append("Project quiet period: \(hours) hour(s)")
            case "extra_roots":
                let roots = updated.extraRoots ?? []
                lines.append("Extra project folders: \(roots.isEmpty ? "None" : roots.joined(separator: ", "))")
            case "names":
                let names = updated.names ?? []
                lines.append("Extra cache names: \(names.isEmpty ? "None" : names.joined(separator: ", "))")
            case "skip":
                let skip = updated.skip ?? []
                lines.append("Additional skipped folders: \(skip.isEmpty ? "None" : skip.joined(separator: ", "))")
            default:
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    static func snapshotValue(
        configURL: URL = ProjectCacheRulesLoader.configURL(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ToolValue {
        do {
            let snapshot = try ProjectCacheRulesLoader.loadConfigSnapshot(from: configURL)
            return snapshotValue(
                config: snapshot.config,
                exists: snapshot.rawData != nil,
                configPath: configURL.path,
                home: home
            )
        } catch {
            var info = stat()
            let exists = lstat(configURL.path, &info) == 0
            return snapshotValue(
                config: nil,
                exists: exists,
                configPath: configURL.path,
                home: home,
                configError: error.localizedDescription
            )
        }
    }

    static func snapshotValue(
        config: ProjectCacheRulesLoader.UserConfig?,
        exists: Bool,
        configPath: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        configError: String? = nil
    ) -> ToolValue {
        let effective = (config.flatMap { try? ProjectCacheRulesLoader.merge(base: .default, document: $0) }) ?? .default
        let validExtraRootURLs = (config?.extraRoots ?? [])
            .compactMap { entry -> URL? in
                guard let resolved = try? ProjectCacheRulesLoader.validatedExtraRoots([entry], home: home).first,
                      TemporaryBuildOutput.isRealDirectory(resolved) else { return nil }
                return resolved
            }
        let resolvedExtraRoots = MiseProjectDiscovery.uniqueSorted(validExtraRootURLs).map(\.path)
        let customValue: ToolValue
        if let config, !config.isEmpty, let encoded = try? ToolValue.encode(config) {
            customValue = encoded
        } else {
            customValue = .null
        }
        var object: [String: ToolValue] = [
            "config_path": .string(configPath),
            "exists": .bool(exists),
            "custom": customValue,
            "effective": .object([
                "quiet_hours": .number(effective.quietHours),
                "names": .array(effective.names.sorted().map(ToolValue.string)),
                "skip": .array(effective.skip.sorted().map(ToolValue.string)),
                "extra_roots": .array(resolvedExtraRoots.map(ToolValue.string)),
            ]),
        ]
        if let configError {
            object["config_error"] = .string(configError)
        }
        return .object(object)
    }

    private static func validatedLineEntries(_ value: ToolValue, field: String) throws -> [String] {
        guard let array = value.array else {
            throw FeatureFailure(message: "\(field) must be an array of strings.")
        }
        var entries: [String] = []
        for item in array {
            guard let entry = item.string else {
                throw FeatureFailure(message: "\(field) entries must be strings.")
            }
            guard !entry.isEmpty,
                  !entry.contains(where: \.isNewline),
                  entry.trimmingCharacters(in: .whitespaces) == entry else {
                throw FeatureFailure(message: "\(field) entries cannot be empty or have leading/trailing whitespace or newlines.")
            }
            entries.append(entry)
        }
        return entries
    }
}
