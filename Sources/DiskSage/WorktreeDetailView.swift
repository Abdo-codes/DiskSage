import AppKit
import SwiftUI

struct WorktreeDetailView: View {
    let item: WorktreeInspection
    let protected: Bool
    let busy: Bool
    @State var integration: String
    var setIntegration: (String) -> Void
    var protect: (Bool) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(URL(fileURLWithPath: item.worktree.path).lastPathComponent).font(.title2.bold())
                Text(item.worktree.path).font(.callout.monospaced()).textSelection(.enabled)
                HStack {
                    Button("Reveal", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.worktree.path)]) }
                    Button("Open Terminal", systemImage: "terminal") {
                        NSWorkspace.shared.open([URL(fileURLWithPath: item.worktree.path)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: .init())
                    }
                    Button(protected ? "Remove Protection…" : "Keep Worktree", systemImage: protected ? "lock.open" : "lock") { protect(!protected) }.disabled(busy)
                }
                if !item.blockers.isEmpty {
                    GroupBox("Removal blocked") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(item.blockers.enumerated()), id: \.offset) { _, reason in Label(reason, systemImage: "lock.shield") }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if item.isDisposable { Label("Disposable checkout — branches and committed work stay.", systemImage: "checkmark.shield").foregroundStyle(.secondary) }
                else if item.requiresDiscardApproval { WorktreeDiscardReviewView(item: item) }
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow { Text("Checkout estimate"); Text(item.estimatedBytes.diskSize) }
                    GridRow { Text("Staged / modified / conflicts"); Text("\(item.staged.count) / \(item.modified.count) / \(item.conflicted.count)") }
                    GridRow { Text("Untracked / ignored"); Text("\(item.untracked.count) / \(item.ignoredFileCount)") }
                    GridRow { Text("Upstream ahead / behind"); Text(item.ahead.map { "\($0) / \(item.behind ?? 0)" } ?? "Unknown (no upstream)") }
                    GridRow { Text("Integration"); Text(item.merged.map { $0 ? "HEAD is an ancestor" : "Not proven merged" } ?? "Not selected") }
                }.font(.callout)
                Text("HEAD \(item.worktree.head)").font(.caption.monospaced()).textSelection(.enabled)
                Text(item.activity).font(.caption).foregroundStyle(.secondary)
                Text("Inspected \(item.inspectedAt.formatted()). Estimates include checkout files, exclude shared Git data, and may share APFS storage.")
                    .font(.caption).foregroundStyle(.secondary)
                GroupBox("Integration reference") {
                    VStack(alignment: .leading) {
                        TextField("refs/heads/main", text: $integration)
                            .accessibilityLabel("Full integration reference")
                        HStack { Button("Apply & Refresh") { setIntegration(integration) }.disabled(busy); if let oid = item.integrationOID { Text(String(oid.prefix(12))).font(.caption.monospaced()) } }
                        Text("Choose explicitly. Squash/rebase merges may remain unproven. Cached upstream: \(item.upstream ?? "Unknown").")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(4)
                }
                paths("Staged", item.staged); paths("Modified", item.modified); paths("Conflicted", item.conflicted)
                paths("Untracked — includes directory contents", item.untracked)
                if item.hasIgnoredFiles { WorktreeIgnoredFilesView(item: item) }
                paths("Commits absent from cached remote refs (up to 31)", item.localCommits)
                paths("Retained local branches/tags", item.retainedRefs.keys.sorted().map { "\($0) \(item.retainedRefs[$0]!)" })
                Text("Local branches are not a remote backup. Shared stashes are untouched and do not prove that checkout files were saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
    }
    @ViewBuilder private func paths(_ title: String, _ values: [String]) -> some View {
        if !values.isEmpty {
            DisclosureGroup("\(title) (\(values.count))") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(values.prefix(100).enumerated()), id: \.offset) { _, value in Text(value).font(.caption.monospaced()).textSelection(.enabled) }
                    if values.count > 100 { Text("Showing the first 100 entries. Full paths are available through inspect_worktree.").font(.caption) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
