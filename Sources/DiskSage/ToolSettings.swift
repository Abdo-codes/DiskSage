import AppKit
import ServiceManagement

enum ToolSettings {
    struct Entry {
        let key: String
        let label: String
        let fallback: ToolValue
        let schema: [String: Any]
    }
    static var entries: [String: Entry] {
        func bool(_ key: String, _ label: String, _ value: Bool = false) -> Entry {
            Entry(key: key, label: label, fallback: .bool(value), schema: MCPManagementSchema.boolean)
        }
        func text(_ key: String, _ label: String) -> Entry {
            Entry(key: key, label: label, fallback: .string(""), schema: ["type": "string", "maxLength": 1_024])
        }
        return [
            "automatic_cleanup_enabled": bool("automaticCleanupEnabled", "Low-disk automatic cleanup", true),
            "cleanup_threshold_gib": Entry(key: "cleanupThresholdGiB", label: "Low-disk threshold (GiB)", fallback: .integer(15), schema: MCPManagementSchema.integer(5, 100)),
            "launch_at_login": bool("launchAtLogin", "Launch at login"),
            "agent_cleanup_policy": Entry(key: "agentCleanupPolicy", label: "Agent cleanup access", fallback: .string("confirm"), schema: MCPManagementSchema.choice(["disabled", "confirm", "automaticLowRisk"])),
            "built_in_cleanup_enabled": bool("builtInAgentCleanupEnabled", "Built-in advisors may request cleanup"),
            "agent_provider": Entry(key: "agentProvider", label: "Advisor", fallback: .string("codex"), schema: MCPManagementSchema.choice(["codex", "claude", "apple", "ollama"])),
            "codex_executable_path": text("codexExecutablePath", "Codex executable path"),
            "claude_executable_path": text("claudeExecutablePath", "Claude executable path"),
            "codex_model": text("codexModel", "Codex model"), "claude_model": text("claudeModel", "Claude model"),
            "ollama_model": text("ollamaModel", "Ollama model (cloud models may send metadata remotely)"),
            "codex_metadata_consent": bool("agentMetadataConsent", "Share metadata through Codex"),
            "claude_metadata_consent": bool("claudeMetadataConsent", "Share metadata through Claude"),
            "keep_paths": Entry(key: KeepRules.pathsKey, label: "Kept paths (one per line)", fallback: .string(""),
                                schema: ["type": "string", "maxLength": 16_384]),
            "keep_simulator_names": Entry(key: KeepRules.simulatorNamesKey, label: "Kept simulator names (patterns)", fallback: .string(""),
                                          schema: ["type": "string", "maxLength": 4_096]),
            "ollama_metadata_consent": bool("ollamaMetadataConsent", "Share metadata through Ollama (including cloud models)")]
    }
    static var schema: [String: [String: Any]] { entries.mapValues(\.schema) }
    static func read(defaults: UserDefaults = .standard, loginEnabled: Bool? = nil) -> [String: ToolValue] {
        var result = entries.mapValues { entry -> ToolValue in
            guard let value = defaults.object(forKey: entry.key),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
                  let decoded = try? JSONDecoder().decode(ToolValue.self, from: data) else { return entry.fallback }
            return decoded
        }
        result["launch_at_login"] = .bool(loginEnabled ?? (SMAppService.mainApp.status == .enabled))
        return result
    }
    static func validate(_ patch: [String: ToolValue]) throws {
        guard !patch.isEmpty else { throw FeatureFailure(message: "Supply at least one setting.") }
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(patch))
        try MCPManagementSchema.validate(raw, schema: ["type": "object", "properties": schema])
        if let threshold = patch["cleanup_threshold_gib"]?.integer, threshold % 5 != 0 {
            throw FeatureFailure(message: "The cleanup threshold must use 5 GiB steps.")
        }
        if let paths = patch["keep_paths"]?.string, !KeepRules.invalidPaths(paths).isEmpty {
            throw FeatureFailure(message: "Kept paths must be absolute or start with ~/.")
        }
        for key in ["codex_executable_path", "claude_executable_path"] {
            if let path = patch[key]?.string, !path.isEmpty,
               (!path.hasPrefix("/") || !FileManager.default.isExecutableFile(atPath: path)) {
                throw FeatureFailure(message: "Executable paths must be absolute paths to existing executable files.")
            }
        }
    }
    @MainActor static func apply(_ patch: [String: ToolValue]) throws {
        try validate(patch)
        if let enabled = patch["launch_at_login"]?.bool, enabled != (SMAppService.mainApp.status == .enabled) {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        }
        for (key, value) in patch where key != "launch_at_login" {
            let data = try JSONEncoder().encode(value)
            let raw = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            UserDefaults.standard.set(raw, forKey: entries[key]!.key)
        }
        NotificationCenter.default.post(name: .diskSageSettingsChanged, object: nil)
    }
    static func configuration(_ provider: AgentProvider, values: [String: ToolValue]) -> (AgentConfiguration, Bool) {
        let configuration = AgentConfiguration(provider: provider,
            executablePath: values["\(provider.rawValue)_executable_path"]?.string ?? "",
            model: values["\(provider.rawValue)_model"]?.string ?? "",
            allowsCleanupRequests: values["built_in_cleanup_enabled"]?.bool == true && values["agent_cleanup_policy"]?.string != "disabled")
        return (configuration, provider == .apple || values["\(provider.rawValue)_metadata_consent"]?.bool == true)
    }
    static func details(_ patch: [String: ToolValue]) -> String {
        patch.keys.sorted().map { key in
            let value = patch[key]!
            let display: String
            if key == "agent_cleanup_policy", let raw = value.string, let policy = AgentCleanupPolicy(rawValue: raw) { display = policy.title }
            else if key == "agent_provider", let raw = value.string, let provider = AgentProvider(rawValue: raw) { display = provider.title }
            else if value.string == "" { display = "Use default / detect automatically" }
            else { display = value.display }
            return "\(entries[key]?.label ?? key): \(display)"
        }.joined(separator: "\n")
    }
}

extension Notification.Name {
    static let diskSageSettingsChanged = Self("DiskSage.settingsChanged")
    static let diskSageOpenWindow = Self("DiskSage.openWindow")
}
