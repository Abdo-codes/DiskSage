import AppKit
import ComposableArchitecture
import SwiftUI
import Testing
@testable import DiskSage

@MainActor
struct WorktreePresentationTests {
    @Test func reviewAndConfirmationRenderOffscreen() throws {
        _ = NSApplication.shared
        var clean = WorktreesFeatureTests.item()
        clean.worktree.path = "/Users/developer/Projects/Example-feature"
        clean.worktree.commonDirectory = "/Users/developer/Projects/Example/.git"
        clean.worktree.head = String(repeating: "a", count: 40)
        clean.retainedRefs = ["refs/heads/feature": clean.worktree.head]
        clean.estimatedBytes = 1_500_000_000
        clean.localCommits = [clean.worktree.head + " Add feature"]
        clean.ignored = [".build/", ".env"]
        clean.ignoredFiles = [.init(path: ".build/output", estimatedBytes: 1000, symbolicLink: false),
            .init(path: ".env", estimatedBytes: 4096, symbolicLink: false)]
        clean.activity = "No matching process observed; editor and agent activity is unknown."
        var disposable = clean
        disposable.cleanupConcerns = []
        disposable.ignored = [".build/"]
        disposable.ignoredFiles = [.init(path: ".build/output", estimatedBytes: 1000, symbolicLink: false)]
        disposable.untracked = [".build-dd/"]
        disposable.removalWarnings = ["Generated caches and anchored Claude markers are included."]
        try render(WorktreeConfirmationView(preview: WorktreePreview(items: [disposable]), confirm: { _, _ in }, dismiss: {}),
            size: NSSize(width: 708, height: 620), name: "worktree-simple-confirmation")
        var blocked = clean
        blocked.worktree.path = "/Users/developer/Projects/Example-work-in-progress"
        blocked.worktree.branch = "refs/heads/work-in-progress"
        blocked.modified = ["Sources/An important file.swift"]
        blocked.blockers = ["Preserve modified files before removal."]
        var state = AppFeature.State()
        state.worktrees.items = [clean, blocked]; state.worktrees.loaded = true
        state.worktrees.configuration.roots = ["/Users/developer/Projects"]
        let model = AppModel(store: ManagementTestSupport.store(state))
        try render(WorktreeReviewView(model: model), size: NSSize(width: 1100, height: 720), name: "worktree-review")
        state.worktrees.activeRemoval = WorktreePreview(items: [disposable])
        state.worktrees.removing = true
        let running = AppModel(store: ManagementTestSupport.store(state))
        #expect(running.worktrees.pending == nil)
        try render(WorktreeReviewView(model: running), size: NSSize(width: 1100, height: 720), name: "worktree-background-removal")
        try render(WorktreeDetailView(item: clean, protected: false, busy: false, integration: "refs/heads/main", setIntegration: { _ in }, protect: { _ in }),
            size: NSSize(width: 620, height: 760), name: "worktree-detail")
        try render(WorktreeConfirmationView(preview: WorktreePreview(items: [clean]), confirm: { _, _ in }, dismiss: {}),
            size: NSSize(width: 708, height: 700), name: "worktree-confirmation")
        var discard = clean
        discard.modified = ["Sources/Local edits.swift"]
        discard.untracked = [".build-dd/"]
        discard.removalWarnings = ["Uncommitted files will be permanently deleted.", "Private Git metadata will be deleted: CLAUDE_BASE.",
            "Nested Git repository data will be deleted: .build-dd/SourcePackages/checkouts/dependency/.git."]
        try render(WorktreeConfirmationView(preview: WorktreePreview(items: [discard]), confirm: { _, _ in }, dismiss: {}),
            size: NSSize(width: 708, height: 760), name: "worktree-discard-confirmation")
    }
    private func render<V: View>(_ view: V, size: NSSize, name: String) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.setFrameSize(size)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= Int(size.width) && bitmap.pixelsHigh >= Int(size.height))
        #expect(!window.isVisible)
        if let path = ProcessInfo.processInfo.environment["DISKSAGE_WORKTREE_PREVIEW_DIRECTORY"] {
            let folder = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appending(path: name + ".png"))
        }
    }
}
