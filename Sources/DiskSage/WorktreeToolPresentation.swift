import Foundation

enum WorktreeToolPresentation {
    static func preview(_ preview: WorktreePreview) throws -> ToolValue {
        var checkouts: [ToolValue] = [], bytes = 0
        for item in preview.items {
            let value = try summary(item), size = try JSONEncoder().encode(value).count
            if bytes + size > 20_000 { break }
            checkouts.append(value); bytes += size
        }
        let data: ToolValue = .object(["snapshot_token": .string(preview.id.uuidString), "estimated_bytes": .integer(Int(preview.estimatedBytes)),
            "eligible_total": .integer(preview.quickReviewTotal ?? preview.items.count),
            "ignored_files_require_native_approval": .bool(preview.requiresIgnoredApproval),
            "discard_requires_native_approval": .bool(preview.requiresDiscardApproval),
            "extra_acknowledgement_required": .bool(preview.requiresExtraAcknowledgement),
            "checkouts_total": .integer(preview.items.count), "checkouts_truncated": .bool(checkouts.count < preview.items.count),
            "checkouts": .array(checkouts)])
        // MCP carries both text and structured forms. Keep headroom for that framing.
        guard try JSONEncoder().encode(AgentToolReply(data: data)).count < 24_000 else {
            throw FeatureFailure(message: "This preview exceeds the tool response limit. Review fewer checkouts per batch; full risks remain available through inspect_worktree and in DiskSage.")
        }
        return data
    }
    static func summary(_ item: WorktreeInspection) throws -> ToolValue {
        .object(["id": .string(item.id), "worktree": try .encode(item.worktree), "inspected_at": try .encode(item.inspectedAt),
            "can_remove": .bool(item.canRemove), "label": .string(item.label), "blockers": try .encode(item.blockers),
            "can_request_removal": .bool(item.canRequestRemoval), "removal_warnings": try .encode(Array(item.discardReasons.prefix(3))),
            "disposable": .bool(item.isDisposable), "cleanup_concerns": try .encode(Array((item.cleanupConcerns ?? []).prefix(3))),
            "removal_warning_count": .integer(item.discardReasons.count), "removal_warnings_truncated": .bool(item.discardReasons.count > 3),
            "discard_approval_required": .bool(item.requiresDiscardApproval),
            "estimated_bytes": .integer(Int(item.estimatedBytes)), "staged_count": .integer(item.staged.count),
            "modified_count": .integer(item.modified.count), "conflicted_count": .integer(item.conflicted.count),
            "untracked_count": .integer(item.untracked.count), "ignored_count": .integer(item.ignoredFileCount), "ignored_bytes": .integer(Int(item.ignoredBytes)),
            "ignored_approval_required": .bool(item.hasIgnoredFiles),
            "retained_ref_count": .integer(item.retainedRefs.count), "cached_remote_absent_commits_shown": .integer(item.localCommits.count),
            "upstream": try .encode(item.upstream), "ahead": try .encode(item.ahead), "behind": try .encode(item.behind),
            "integration_ref": try .encode(item.integrationRef), "integration_oid": try .encode(item.integrationOID),
            "merged": try .encode(item.merged), "activity": .string(item.activity)])
    }
    static func detail(_ item: WorktreeInspection, args: [String: ToolValue]) throws -> ToolValue {
        let groups: [(String, [String])] = [("staged", item.staged), ("modified", item.modified), ("conflicted", item.conflicted),
            ("untracked", item.untracked), ("removal_warning", item.discardReasons), ("cleanup_concern", item.cleanupConcerns ?? []), ("ignored_scope", item.ignored), ("cached_remote_absent_commit", item.localCommits),
            ("retained_ref", item.retainedRefs.keys.sorted().map { "\($0) \(item.retainedRefs[$0]!)" })]
        var entries = groups.flatMap { kind, values in values.map { ToolValue.object(["kind": .string(kind), "value": .string($0)]) } }
        entries += (item.ignoredFiles ?? []).map { .object(["kind": .string("ignored"), "value": .string($0.path),
            "estimated_bytes": .integer(Int($0.estimatedBytes)), "symbolic_link": .bool($0.symbolicLink)]) }
        return .object(["inspection": try summary(item), "details": try ToolPage.make(entries, key: "entries",
            offset: args["offset"]?.integer ?? 0, limit: args["limit"]?.integer ?? 50)])
    }
}
