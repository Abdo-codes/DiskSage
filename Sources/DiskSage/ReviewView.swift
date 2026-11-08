import SwiftUI

struct ReviewView: View {
    @Bindable var model: AppModel
    @AppStorage("reviewSelectedSection") private var section = "caches"
    var body: some View {
        VStack(spacing: 0) {
            Picker("Cleanup section", selection: $section) {
                Text("Caches & Generated Files").tag("caches")
                Text("Git Worktrees").tag("worktrees")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)
            .padding(12)
            Divider()
            if section == "worktrees" { WorktreeReviewView(model: model) }
            else { CacheReviewView(model: model) }
        }
        .frame(minWidth: 800, minHeight: 560)
    }
}
