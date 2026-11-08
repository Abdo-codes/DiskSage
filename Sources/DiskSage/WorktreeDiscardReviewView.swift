import SwiftUI

/// Searchable, bounded pages keep large untracked inventories reviewable without rendering every path.
struct WorktreeDiscardReviewView: View {
    let item: WorktreeInspection
    @State private var query = ""
    @State private var page = 0
    private var entries: [String] {
        [("Staged", item.staged), ("Modified", item.modified), ("Conflicted", item.conflicted), ("Untracked", item.untracked)]
            .flatMap { kind, paths in paths.map { "\(kind): \($0)" } }
    }
    private var filtered: [String] { query.isEmpty ? entries : entries.filter { $0.localizedCaseInsensitiveContains(query) } }
    private var pages: Int { max(1, (filtered.count + 24) / 25) }
    var body: some View {
        GroupBox("Data requiring your explicit discard approval") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(item.discardReasons.enumerated()), id: \.offset) { _, reason in
                    Label(reason, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled)
                }
                if !entries.isEmpty {
                    DisclosureGroup("Review changed and untracked paths (\(entries.count))") {
                        Text("Directory entries include everything inside them. Retained commits cannot restore uncommitted files.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Search changed paths", text: $query).textFieldStyle(.roundedBorder)
                        ForEach(Array(filtered.dropFirst(min(page, pages - 1) * 25).prefix(25).enumerated()), id: \.offset) { _, path in
                            Text(path).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        HStack {
                            Text("Page \(min(page + 1, pages)) of \(pages) • \(filtered.count) matches").font(.caption)
                            Spacer()
                            Button("Previous") { page = max(0, page - 1) }.disabled(page == 0)
                            Button("Next") { page += 1 }.disabled(page + 1 >= pages)
                        }.controlSize(.small)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.onChange(of: query) { _, _ in page = 0 }
    }
}
