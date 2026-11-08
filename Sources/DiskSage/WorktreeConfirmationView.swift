import SwiftUI

struct WorktreeConfirmationView: View {
    let preview: WorktreePreview
    var error: String?
    var confirm: (Bool, Bool) -> Void
    var dismiss: () -> Void
    @State private var acknowledgeLoss = false
    private var protection: Bool { preview.protectionChange == false }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(protection ? "Remove DiskSage protection?" : "Delete selected worktrees?", systemImage: protection ? "lock.open" : "trash")
                .font(.title2.bold())
            if protection {
                Text("This allows future manual review. It does not delete files.")
            } else {
                Text("Selected folders: \(preview.items.count) · \(preview.estimatedBytes.diskSize) estimated")
                    .font(.title3).monospacedDigit()
                Text("Your repository’s branches and committed work stay. The selected checkout folders and their generated caches are deleted.")
                if !preview.requiresExtraAcknowledgement {
                    Label("No unsaved source or unretained work found.", systemImage: "checkmark.shield").foregroundStyle(.secondary)
                }
            }
            if let total = preview.quickReviewTotal, total > preview.items.count {
                Text("Reviewing \(preview.items.count) of \(total) unchanged worktrees.").font(.caption).foregroundStyle(.secondary)
            }
            WorktreeConfirmationItems(items: preview.items, protection: protection)
            if !protection && preview.requiresExtraAcknowledgement {
                Label("Some local files or recovery data may be lost permanently. Review the details above.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Toggle("Also delete the unsaved files and private data shown above.", isOn: $acknowledgeLoss)
            }
            if !protection {
                Text("Close editors and builds using these folders. DiskSage rechecks the exact files, branches and known activity before deleting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button(protection ? "Remove Protection" : (preview.requiresExtraAcknowledgement ? "Delete Including Unsaved Data" : "Delete Worktrees"), role: .destructive) {
                    confirm(preview.requiresIgnoredApproval, preview.requiresDiscardApproval)
                }.buttonStyle(.borderedProminent).tint(protection ? Color.accentColor : Color.red)
                    .disabled(!protection && preview.requiresExtraAcknowledgement && !acknowledgeLoss)
            }
        }.padding(24).frame(width: 660)
    }
}

private struct WorktreeConfirmationItems: View {
    let items: [WorktreeInspection]
    let protection: Bool
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(URL(fileURLWithPath: item.worktree.path).lastPathComponent).fontWeight(.medium)
                            Spacer()
                            Text(item.estimatedBytes.diskSize).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Text(item.worktree.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        if !protection && !item.isDisposable {
                            ForEach(Array(Set(item.cleanupConcerns ?? [])).sorted(), id: \.self) { concern in Text(concern).font(.callout).foregroundStyle(.orange) }
                        }
                        DisclosureGroup("Details") {
                            if let branch = item.worktree.branch { Text("Keep \(branch)").font(.caption.monospaced()).textSelection(.enabled) }
                            Text("HEAD \(item.worktree.head)").font(.caption.monospaced()).textSelection(.enabled)
                            if !protection && !item.isDisposable {
                                if item.requiresDiscardApproval { WorktreeDiscardReviewView(item: item) }
                                if item.hasIgnoredFiles { WorktreeIgnoredFilesView(item: item) }
                            } else {
                                Text("Generated caches and temporary agent markers are included. Branches remain in the main repository.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider()
                }
            }
        }.frame(minHeight: 100, maxHeight: 280)
    }
}
