import Foundation

struct AppInformation: Codable, Equatable, Sendable {
    static let repository = URL(string: "https://github.com/Abdo-codes/DiskSage")!
    static let documentation = repository.appending(path: "blob/main/README.md")
    static let issues = repository.appending(path: "issues/new")
    static let license = repository.appending(path: "blob/main/LICENSE")
    let version: String?
    let build: String?

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        version = (info["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        build = (info["CFBundleVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    var displayVersion: String {
        if let version, let build { return "\(version) (\(build))" }
        if let version { return version }
        if let build { return "Development build (\(build))" }
        return "Development build"
    }
}

enum MCPOnboardingPreferences {
    static let completionKey = "mcpOnboardingCompleted"
    static var hasExistingData: Bool {
        FileManager.default.fileExists(atPath: CleanupScheduleRepository.standard.fileURL.path) ||
            FileManager.default.fileExists(atPath: CleanupLogger.shared.fileURL.path)
    }
    static func shouldAutoShow(defaults: UserDefaults = .standard, hasExistingData: Bool = false) -> Bool {
        if defaults.object(forKey: completionKey) != nil { return !defaults.bool(forKey: completionKey) }
        // Upgrades should not interrupt an existing menu-bar app session.
        let legacyKeys = ["settingsSelectedTab", "agentProvider", "automaticCleanupEnabled", "cleanupThresholdGiB",
                          "agentCleanupPolicy", "builtInAgentCleanupEnabled", "codexModel", "claudeModel", "ollamaModel"]
        if hasExistingData || legacyKeys.contains(where: { defaults.object(forKey: $0) != nil }) {
            complete(defaults: defaults)
            return false
        }
        return true
    }
    static func complete(defaults: UserDefaults = .standard) { defaults.set(true, forKey: completionKey) }
    static func isVerified(since start: Date, lastContact: Date?, serverError: String?) -> Bool {
        serverError == nil && (lastContact.map { $0 >= start } ?? false)
    }
}
