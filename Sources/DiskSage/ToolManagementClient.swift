import AppKit
import ComposableArchitecture

struct ToolManagementClient: Sendable {
    var settings: @Sendable () -> [String: ToolValue]
    var applySettings: @Sendable ([String: ToolValue]) async throws -> Void
    var grantConsent: @Sendable (AgentProvider) -> Void
    var identity: @Sendable (URL) throws -> FileIdentity
    var receipt: @Sendable (UUID) throws -> ToolMutationReceipt?
    var save: @Sendable ([CleanupSchedule], ToolMutationReceipt) throws -> Void
    var read: @Sendable (String, [String: ToolValue]) async throws -> ToolValue
    var present: @Sendable (String, URL?) async throws -> Void
    var keepPaths: @Sendable ([URL]) async -> Void = { _ in }
    var readProjectCacheRules: @Sendable () -> ToolValue = { .null }
    var loadProjectCacheRulesSnapshot: @Sendable () throws -> ProjectCacheRulesLoader.ConfigSnapshot = { .init(config: .init(), rawData: nil) }
    var saveProjectCacheRules: @Sendable (ProjectCacheRulesLoader.UserConfig, Data?) async throws -> Data = { _, _ in Data() }
    var projectCacheRulesPath: @Sendable () -> String = { "" }
    var projectCacheRulesHome: @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
}

extension ToolManagementClient: DependencyKey {
    static let liveValue = Self(settings: { ToolSettings.read() },
        applySettings: { patch in try await MainActor.run { try ToolSettings.apply(patch) } },
        grantConsent: { provider in
            if let key = provider.consentKey { UserDefaults.standard.set(true, forKey: key) }
        }, identity: { try ScheduledFolderPolicy.identity(of: $0) },
        receipt: { id in try CleanupScheduleRepository.standard.receipts().first { $0.request.requestID == id } },
        save: { try CleanupScheduleRepository.standard.save($0, receipt: $1) },
        read: { name, args in
            if name == "list_models" {
                switch args["provider"]?.string {
                case "ollama": return try await ToolValue.encode(OllamaAdvisor().availableModels())
                case "claude": return .array(["sonnet", "opus", "haiku"].map(ToolValue.string))
                case "apple": return .array([.string("system")])
                default: return .object(["models": .array([]), "note": .string("Codex accepts a model ID or its CLI default.")])
                }
            }
            return try await Task.detached(priority: .utility) {
                if name == "explain_path" {
                    guard let path = args["path"]?.string else {
                        throw FeatureFailure(message: "A path string is required.")
                    }
                    let activity = try CleanupActivity.capture()
                    let diagnostic = PathDiagnostics.explain(path, activity: activity)
                    return try ToolValue.encode(diagnostic)
                }
                if name == "get_history" {
                    let values = try CleanupLogger.shared.recentCleanups(limit: 100).map { item -> ToolValue in
                        var value = try ToolValue.encode(item).object!
                        value["items"] = nil; value["details_tool"] = .string("get_logs")
                        value["item_description"] = .string(item.itemDescription)
                        return .object(value)
                    }
                    return try ToolPage.make(values, key: "history", offset: args["offset"]?.integer ?? 0, limit: args["limit"]?.integer ?? 20)
                }
                let runID = args["run_id"]?.string.flatMap(UUID.init(uuidString:))
                let values = try CleanupLogger.shared.events(runID: runID).reversed().map { try ToolValue.encode($0) }
                return try ToolPage.make(values, key: "events", offset: args["offset"]?.integer ?? 0, limit: args["limit"]?.integer ?? 100)
            }.value
        }, present: { screen, url in
            try await MainActor.run {
                if let url { NSWorkspace.shared.activateFileViewerSelecting([url]); return }
                if screen == "logs" {
                    try CleanupLogger.shared.prepareDirectory()
                    guard NSWorkspace.shared.open(CleanupLogger.shared.directory) else { throw FeatureFailure(message: "Log folder could not be opened.") }
                } else if screen == "quit" {
                    NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.2)
                } else {
                    NotificationCenter.default.post(name: .diskSageOpenWindow, object: screen)
                }
            }
        }, keepPaths: { urls in
            await MainActor.run { _ = KeepRules.keep(urls) }
        }, readProjectCacheRules: {
            ToolProjectCacheRules.snapshotValue()
        }, loadProjectCacheRulesSnapshot: {
            try ProjectCacheRulesLoader.loadConfigSnapshot(from: ProjectCacheRulesLoader.configURL())
        }, saveProjectCacheRules: { config, expected in
            let written = try ProjectCacheRulesLoader.save(config, expectedExistingData: .some(expected))
            await MainActor.run {
                NotificationCenter.default.post(name: .diskSageProjectCacheRulesChanged, object: nil)
            }
            return written
        }, projectCacheRulesPath: {
            ProjectCacheRulesLoader.configURL().path
        }, projectCacheRulesHome: {
            FileManager.default.homeDirectoryForCurrentUser
        })
    static let testValue = Self(settings: { ToolSettings.entries.mapValues(\.fallback) },
        applySettings: { _ in }, grantConsent: { _ in }, identity: { _ in FileIdentity(device: 1, inode: 2) },
        receipt: { _ in nil }, save: { _, _ in }, read: { _, _ in .array([]) }, present: { _, _ in },
        keepPaths: { _ in },
        readProjectCacheRules: {
            ToolProjectCacheRules.snapshotValue(
                config: .init(),
                exists: false,
                configPath: "/tmp/rules.json",
                home: URL(fileURLWithPath: "/tmp", isDirectory: true)
            )
        },
        loadProjectCacheRulesSnapshot: { .init(config: .init(), rawData: nil) },
        saveProjectCacheRules: { _, _ in Data() },
        projectCacheRulesPath: { "/tmp/rules.json" },
        projectCacheRulesHome: { FileManager.default.homeDirectoryForCurrentUser })
}

extension DependencyValues {
    var management: ToolManagementClient {
        get { self[ToolManagementClient.self] }
        set { self[ToolManagementClient.self] = newValue }
    }
}
