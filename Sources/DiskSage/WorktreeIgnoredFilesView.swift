import SwiftUI

/// A bounded page of paths; file contents are never loaded for review.
struct WorktreeIgnoredFilesView: View {
    let item: WorktreeInspection
    @State private var query = ""
    @State private var page = 0
    private let pageSize = 25
    private var files: [WorktreeIgnoredFile] { item.ignoredFiles ?? [] }
    private var filtered: [WorktreeIgnoredFile] {
        query.isEmpty ? files : files.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }
    private var pageCount: Int { max(1, (filtered.count + pageSize - 1) / pageSize) }
    private var visible: [WorktreeIgnoredFile] { Array(filtered.dropFirst(min(page, pageCount - 1) * pageSize).prefix(pageSize)) }
    var body: some View {
        DisclosureGroup("Review \(item.ignoredFileCount) ignored files • \(item.ignoredBytes.diskSize) estimated") {
            VStack(alignment: .leading, spacing: 8) {
                Text("These files are included in permanent checkout removal. They may contain local settings, credentials or work that Git never saved.")
                    .font(.caption).foregroundStyle(.secondary)
                if files.isEmpty {
                    ForEach(item.ignored, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                } else {
                    TextField("Search ignored paths", text: $query).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search ignored files in \(item.worktree.path)")
                    ForEach(visible) { file in
                        HStack(alignment: .top) {
                            Text(file.path).font(.caption.monospaced()).textSelection(.enabled)
                            if file.symbolicLink { Text("Link").font(.caption).foregroundStyle(.secondary).help("The link is removed; its target is kept.") }
                            Spacer()
                            Text(file.estimatedBytes.diskSize).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("\(filtered.count) matches • Page \(min(page + 1, pageCount)) of \(pageCount)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Previous") { page = max(0, page - 1) }.disabled(page == 0)
                        Button("Next") { page += 1 }.disabled(page + 1 >= pageCount)
                    }.controlSize(.small)
                }
            }.padding(.top, 6)
        }
        .onChange(of: query) { _, _ in page = 0 }
    }
}
