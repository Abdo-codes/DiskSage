import SwiftUI

struct CLISettingsView: View {
    let provider: AgentProvider
    @Binding var executablePath: String
    @Binding var model: String
    @Binding var consent: Bool
    @State private var showsAdvanced = false

    private var presets: [String] { provider == .claude ? ["sonnet", "opus", "haiku"] : [] }
    private var isInstalled: Bool {
        provider == .claude
            ? ClaudeAdvisor.discoverExecutable(preferredPath: executablePath) != nil
            : CodexAdvisor.discoverExecutable(preferredPath: executablePath) != nil
    }

    var body: some View {
        if provider == .claude {
            Picker("Model", selection: $model) {
                Text("Claude default").tag("")
                ForEach(presets, id: \.self) { Text($0.capitalized).tag($0) }
                if !model.isEmpty, !presets.contains(model) { Text(model).tag(model) }
            }
        }
        LabeledContent("Command-line app") {
            Label(isInstalled ? "Installed" : "Not found", systemImage: isInstalled ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(isInstalled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        }
        Toggle("Share cleanup metadata with \(provider.title)", isOn: $consent)
        Text("Only item categories, sizes, risk levels, generic reasons, and random IDs are shared. File paths and project names stay on this Mac.")
            .font(.caption).foregroundStyle(.secondary)
        DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
            TextField("Executable path", text: $executablePath, prompt: Text("Detect automatically"))
            TextField("Model ID", text: $model, prompt: Text("Use provider default"))
        }
        Text(provider == .claude ? "Uses your Claude Code sign-in. To sign in, run ‘claude auth login’ in Terminal." : "Uses your existing Codex sign-in.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
