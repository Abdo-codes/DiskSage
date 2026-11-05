import Foundation

extension AppFeature {
    func managementSnapshot(name: String, args: [String: ToolValue], state: State) throws -> ToolValue? {
        switch name {
        case "get_dashboard":
            var result: [String: ToolValue] = ["status": .string(state.statusMessage), "busy": .bool(state.isBusy),
                "operation": .string(String(describing: state.operation)), "free_space_bytes": .integer(Int(client.freeSpace())),
                "selected_ids": try .encode(state.selection.sorted { $0.uuidString < $1.uuidString }),
                "completed_count": .integer(state.cleanupCompletedCount), "total_count": .integer(state.cleanupTotalCount),
                "current_item": .string(state.cleanupCurrentItem), "failed_count": .integer(state.cleanupFailures.count),
                "last_recovered_bytes": .integer(Int(state.lastRecoveredBytes)),
                "last_automatic_cleanup": try .encode(state.lastAutomaticCleanup),
                "automatic_cleanup_summary": .string(state.automaticCleanupSummary),
                "removed_entry_count": .integer(state.cleanupRemovedEntryCount),
                "current_items": .object(Dictionary(uniqueKeysWithValues: state.cleanupActiveItems.map { ($0.key.uuidString, .string($0.value)) })),
                "recommendation_count": .integer(state.recommendations.count), "advice_summary": .string(state.recommendationSummary),
                "disk_usage": try .encode(state.diskUsage), "last_scan": try .encode(state.lastScanDate),
                "error": try .encode(state.errorMessage), "schedule_error": try .encode(state.scheduleError)]
            let information = AppInformation()
            result["app"] = .object(["name": .string("DiskSage"), "version": .string(information.displayVersion),
                "developer": .string("Abdo Eaita"), "license": .string("MIT"),
                "source_url": .string(AppInformation.repository.absoluteString),
                "documentation_url": .string(AppInformation.documentation.absoluteString)])
            result["last_mcp_contact"] = try .encode(state.lastMCPContact)
            if let report = state.cleanupReport {
                result["cleanup_report"] = .object(["estimated_removed_bytes": .integer(Int(report.estimatedRemovedBytes)),
                    "actual_recovered_bytes": .integer(Int(report.actualRecoveredBytes)),
                    "free_space_before": .integer(Int(report.freeSpaceBefore)), "free_space_after": .integer(Int(report.freeSpaceAfter)),
                    "completed_count": .integer(report.items.count), "failed_count": .integer(report.failures.count),
                    "removed_entry_count": .integer(report.removedEntryCount), "logging_error": try .encode(report.loggingError)])
            }
            if let id = state.operationID { result["operation_id"] = .string(id.uuidString) }
            if let pending = state.pendingDeletionRequest {
                result["confirmation"] = .object(["id": .string(pending.id.uuidString), "kind": .string("permanent_deletion"),
                    "candidate_ids": try .encode(pending.candidates.map(\.id)), "candidate_count": .integer(pending.candidates.count)])
            }
            if let pending = state.pendingManagementApproval {
                result["confirmation"] = .object(["id": .string(pending.id.uuidString), "kind": .string("management"),
                    "title": .string(pending.title), "details": .string(pending.details)])
            }
            return .object(result)
        case "list_candidates":
            let query = args["query"]?.string ?? "", risk = args["risk"]?.string ?? "all"
            let values = state.candidates.filter {
                let matches = query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.url.path.localizedCaseInsensitiveContains(query)
                let level = $0.risk == .low ? "low" : ($0.risk == .high ? "high" : "medium")
                return matches && (risk == "all" || risk == level)
            }
            var page = try ToolPage.make(values.map { candidateSummary($0, state: state) }, key: "candidates",
                offset: args["offset"]?.integer ?? 0, limit: args["limit"]?.integer ?? 20).object!
            page["last_scan"] = try .encode(state.lastScanDate)
            page["scan_total_count"] = .integer(state.candidates.count)
            return .object(page)
        case "list_schedules":
            guard state.schedulesLoaded else { throw FeatureFailure(message: "Schedules are not loaded. Open or reload DiskSage Settings.") }
            var page = try ToolPage.make(state.schedules.map(scheduleSummary), key: "schedules",
                offset: args["offset"]?.integer ?? 0, limit: args["limit"]?.integer ?? 20).object!
            page["time_zone"] = .string(calendar.timeZone.identifier); page["error"] = try .encode(state.scheduleError)
            return .object(page)
        case "get_settings": return .object(management.settings())
        case "get_mcp_setup":
            let setup = MCPConnectionInstructions.current
            return .object(["claude": .string(setup.claudeCommand), "codex": .string(setup.codexCommand), "stdio": .string(setup.launchCommand),
                "verification_prompt": .string(MCPConnectionInstructions.verificationPrompt)])
        case "list_advisors":
            let settings = management.settings()
            return .array(AgentProvider.allCases.map { provider in
                let (configuration, consent) = ToolSettings.configuration(provider, values: settings)
                let ready: String
                switch provider {
                case .codex, .claude:
                    ready = AgentReadinessClient().executableFound(configuration) ? "CLI found; sign-in and quota unverified" : "CLI not found"
                case .apple: ready = AppleAdvisor.unavailableReason ?? "On-device model available"
                case .ollama: ready = "Use list_models to check the local service and model availability"
                }
                return .object(["provider": .string(provider.rawValue), "name": .string(provider.title),
                    "model": .string(configuration.model), "executable_path": .string(configuration.executablePath),
                    "metadata_consent": .bool(consent), "readiness": .string(ready), "may_request_cleanup": .bool(configuration.allowsCleanupRequests)])
            })
        default: return nil
        }
    }
    func candidateSummary(_ value: CleanupCandidate, state: State) -> ToolValue {
        var result: [String: ToolValue] = ["id": .string(value.id.uuidString), "name": .string(value.name), "path": .string(value.url.path),
            "category": .string(value.category.rawValue), "risk": .string(value.risk == .low ? "low" : (value.risk == .high ? "high" : "medium")),
            "bytes": .integer(Int(value.size)), "reason": .string(value.reason), "deletion_scope": .string(String(localized: value.deletionScope)),
            "selected": .bool(state.selection.contains(value.id))]
        result["recommendation"] = state.recommendations[value.id].flatMap { try? .encode($0) }
        result["cleanup_error"] = state.cleanupFailures.first(where: { $0.candidate.id == value.id })?
            .errorDescription.map(ToolValue.string)
        return .object(result)
    }
}
