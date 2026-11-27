import AppKit
import SwiftUI

struct WorktreeReviewView: View {
    var model: AppModel
    @State private var focused: String?
    @State private var showPrimary = false
    private var state: WorktreesFeature.State { model.worktrees }
    private var visibleItems: [WorktreeInspection] { state.reviewItems.filter { showPrimary || !$0.worktree.main } }
    private var selectedItems: [WorktreeInspection] { state.reviewItems.filter { state.selection.contains($0.id) } }
    private var repositories: [String] { Set(visibleItems.map { $0.worktree.commonDirectory }).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Git Worktrees").font(.title2.bold())
                    Text("Review obsolete checkouts. Branches stay; removal always needs your confirmation.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if state.loading || state.removing { ProgressView().controlSize(.small).accessibilityLabel("Checking worktrees") }
                Button("Add Folder…", systemImage: "folder.badge.plus", action: chooseFolder).disabled(model.isBusy)
                if state.loading { Button("Cancel") { send(.cancelLoad) } }
                Button("Refresh", systemImage: "arrow.clockwise") { send(state.repositoryRoot.map(WorktreesFeature.Action.loadRepository) ?? .load) }.disabled(model.isBusy)
            }.padding(16)
            if let root = state.repositoryRoot {
                HStack {
                    Text("Repository: \(root)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("Show All Repositories") { send(.load) }.disabled(model.isBusy)
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            if !state.configuration.roots.isEmpty {
                HStack {
                    Menu("Approved folders (\(state.configuration.roots.count))") {
                        ForEach(state.configuration.roots, id: \.self) { path in
                            Button("Remove scope: \(path)") { send(.removeRoot(path)) }
                        }
                    }.disabled(model.isBusy)
                    Text("Local inspection • no fetch • cached remote refs may be stale")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Show primary checkouts", isOn: $showPrimary).font(.caption)
                }.padding(.horizontal, 16).padding(.bottom, 10)
            }
            let suggestions = Self.suggestedAgentRoots(approvedRoots: state.configuration.roots)
            if !suggestions.isEmpty {
                HStack(spacing: 8) {
                    Text("Detected agent worktrees:").font(.caption).foregroundStyle(.secondary)
                    ForEach(suggestions, id: \.path) { suggestion in
                        Button("Add \(suggestion.label)", systemImage: "folder.badge.plus") {
                            send(.addRoot(suggestion.path))
                        }
                        .font(.caption).disabled(model.isBusy)
                    }
                    Spacer()
                }.padding(.horizontal, 16).padding(.bottom, 10)
            }
            if let error = state.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).padding(12) }
            if !state.warnings.isEmpty {
                DisclosureGroup("Inspection warnings (\(state.warnings.count))") {
                    ForEach(state.warnings, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            if !state.results.isEmpty {
                DisclosureGroup("Last removal: \(state.results.filter(\.succeeded).count) removed, \(state.results.filter { !$0.succeeded }.count) need attention") {
                    ForEach(state.results) { result in
                        Label("\(result.path): \(result.message)", systemImage: result.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(.caption).textSelection(.enabled)
                    }
                }.padding(12)
            }
            if state.removing {
                WorktreeRemovalProgressView(count: state.activeRemoval?.items.count ?? 0, cancelling: state.cancelling,
                    cancel: { send(.cancelQueued) })
            }
            Divider()
            if visibleItems.isEmpty {
                ContentUnavailableView(state.loading ? "Inspecting repositories…" : "No linked worktrees to review", systemImage: "arrow.triangle.branch",
                    description: Text("Add a repository or projects folder. DiskSage checks registered worktrees within that approved scope."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(selection: $focused) {
                        ForEach(repositories, id: \.self) { repository in
                            Section(URL(fileURLWithPath: repository).deletingLastPathComponent().lastPathComponent) {
                                ForEach(visibleItems.filter { $0.worktree.commonDirectory == repository }) { item in
                                    row(item).tag(item.id)
                                }
                            }
                        }
                    }.frame(minWidth: 250, idealWidth: 330)
                    if let item = visibleItems.first(where: { $0.id == focused }) {
                        WorktreeDetailView(item: item, protected: state.configuration.protectedIDs.contains(item.id), busy: model.isBusy,
                            integration: state.configuration.integrationRefs[item.worktree.commonDirectory] ?? "",
                            setIntegration: { send(.setIntegration(item.worktree.commonDirectory, $0)) },
                            protect: { send(.setProtected(item.id, $0)) })
                            .id(item.id).frame(minWidth: 380)
                    } else {
                        ContentUnavailableView("Inspect a worktree", systemImage: "doc.text.magnifyingglass",
                            description: Text("Select a row to review files, commits and safety checks."))
                            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            Divider()
            HStack {
                Text("\(selectedItems.count) selected • \(selectedItems.reduce(Int64(0)) { $0 + $1.estimatedBytes }.diskSize) estimated")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clean Unchanged Worktrees…", systemImage: "sparkles") { send(.reviewUnused) }
                    .disabled(model.isBusy || WorktreeQuickCleanup.candidates(state.reviewItems).isEmpty)
                    .help("Review unchanged checkouts together. Branches stay; one Delete confirmation removes the selected folders.")
                Button("Remove Selected…", role: .destructive) { send(.preview) }
                    .disabled(model.isBusy || selectedItems.isEmpty)
            }.padding(14)
        }
        .task { if !state.loaded { send(.load) } }
        .onChange(of: visibleItems.map(\.id), initial: true) { _, ids in
            if focused == nil || !ids.contains(focused!) { focused = visibleItems.first(where: \.canRemove)?.id ?? ids.first }
        }
        .sheet(item: Binding(get: { state.pending }, set: { if $0 == nil { send(.dismiss) } })) { preview in
            WorktreeConfirmationView(preview: preview, error: state.error,
                confirm: { ignored, discard in send(.confirm(preview.id, ignoredFilesApproved: ignored, discardChangesApproved: discard)) }, dismiss: { send(.dismiss) })
        }
    }
    private func row(_ item: WorktreeInspection) -> some View {
        HStack(alignment: .top) {
            Toggle("Select \(item.worktree.path)", isOn: Binding(get: { state.selection.contains(item.id) }, set: { selected in
                var ids = state.selection; if selected { ids.insert(item.id) } else { ids.remove(item.id) }; send(.select(ids))
            })).labelsHidden().disabled(!item.canRequestRemoval)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.worktree.branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? "Detached HEAD").fontWeight(.medium)
                Text(item.worktree.path).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                Label(item.label, systemImage: item.worktree.main ? "house" : (item.canRemove ? "checkmark.shield" : "lock.shield"))
                    .font(.caption).foregroundStyle(item.canRemove || item.worktree.main ? Color.secondary : Color.orange)
                if !item.worktree.main, let reason = item.blockers.first {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(item.blockers.joined(separator: "\n"))
                }
                if item.blockers.isEmpty, item.requiresDiscardApproval, !item.isDisposable {
                    Text("Select to review and explicitly discard this checkout’s data.").font(.caption).foregroundStyle(.orange)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .padding(.vertical, 4)
        .accessibilityAddTraits(focused == item.id ? .isSelected : [])
    }
    private func send(_ action: WorktreesFeature.Action) { model.store.send(.worktrees(action)) }

    static func suggestedAgentRoots(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        approvedRoots: [String]
    ) -> [(label: String, path: String)] {
        let home = CleanupPath.fileURL(home)
        return [
            ("~/.t3/worktrees", home.appending(path: ".t3/worktrees", directoryHint: .isDirectory)),
            ("~/.codex/worktrees", home.appending(path: ".codex/worktrees", directoryHint: .isDirectory)),
        ].compactMap { label, url in
            let canonical = CleanupPath.fileURL(url)
            guard TemporaryBuildOutput.isRealDirectory(canonical),
                  !approvedRoots.contains(where: { WorktreePathGuard.contains($0, canonical.path) }) else {
                return nil
            }
            return (label, canonical.path)
        }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Allow Inspection"
        panel.message = "Approve this folder for local Git worktree discovery. No files are removed by adding it."
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { send(.addRoot(url.path)) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            send(.addRoot(url.path))
        }
    }
}
