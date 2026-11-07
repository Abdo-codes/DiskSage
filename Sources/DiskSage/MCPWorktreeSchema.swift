import Foundation

enum MCPWorktreeSchema {
    static let opaque: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 64]
    static let ids: [String: Any] = ["type": "array", "items": opaque, "maxItems": 300, "uniqueItems": true]
    static var definitions: [MCPManagementSchema.Definition] {
        [.init(name: "refresh_worktrees", description: "Refresh local Git evidence in folders previously approved in Git Worktrees. Optional repository_root limits discovery to one existing repository within approved folders, retaining the same safety policy. It never grants folder access. No fetch or deletion. Returns a job; poll get_job.", properties: ["repository_root": ["type": "string", "minLength": 1, "maxLength": 4096]], readOnly: true, requestID: true),
         .init(name: "list_worktrees", description: "Read the latest worktree inventory, timestamps and safety blockers. First refresh_worktrees. Remote evidence is cached, with unknown freshness.", properties: MCPManagementSchema.page, readOnly: true),
         .init(name: "inspect_worktree", description: "Inspect file paths, ignored output, commits, retained refs and blockers from the latest local inspection.", properties: MCPManagementSchema.page.merging(["worktree_id": opaque]) { $1 }, required: ["worktree_id"], readOnly: true),
         .init(name: "preview_worktree_removal", description: "Preview exact checkout removal, keeping top-level branches. For removal_warnings, explicitly set allow_discard=true to request destructive native review of changes, private metadata or nested repositories. This flag never approves deletion. Hard safety blockers cannot be overridden. Returns an opaque snapshot_token.", properties: ["worktree_ids": ids, "allow_discard": MCPManagementSchema.boolean], required: ["worktree_ids"], readOnly: true),
         .init(name: "preview_unused_worktrees", description: "Preview disposable unchanged checkouts together (up to 300 and the bounded snapshot size). Recognized generated caches and anchored Claude markers are included; unsaved source, secrets and unretained commits are excluded. One native Delete confirmation is required. Requires a completed refresh_worktrees. Returns snapshot_token for remove_worktrees; never deletes automatically.", readOnly: true),
         .init(name: "remove_worktrees", description: "Request removal using a current preview token. ALWAYS requires human confirmation in Git Worktrees, even with automatic agent cleanup enabled. Disposable unchanged worktrees need one native Delete confirmation. Unsaved source/private data requires one extra acknowledgement. Only native approval permits Git to use one force flag. Safety blockers cannot be overridden. Poll get_job; acceptance never proves removal.",
            properties: ["snapshot_token": MCPManagementSchema.uuid], required: ["snapshot_token"], destructive: true, requestID: true),
         .init(name: "set_worktree_protected", description: "Keep a worktree protected in DiskSage. Setting protected=false ALWAYS requires native human approval; it never removes the checkout.",
            properties: ["worktree_id": opaque, "protected": MCPManagementSchema.boolean], required: ["worktree_id", "protected"], requestID: true)]
    }
    static func contains(_ name: String?) -> Bool { definitions.contains { $0.name == name } }
}
