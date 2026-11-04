import SwiftUI

struct OllamaSettingsView: View {
    @AppStorage("ollamaModel") private var selectedModel = ""
    @AppStorage("ollamaMetadataConsent") private var consent = false
    @State private var models: [OllamaModel] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Picker("Ollama model", selection: $selectedModel) {
            Text("Choose a model").tag("")
            if !selectedModel.isEmpty, !models.contains(where: { $0.name == selectedModel }) {
                Text("\(selectedModel) (not currently listed)").tag(selectedModel)
            }
            ForEach(models) { model in Text(model.title).tag(model.name) }
        }
        HStack {
            Text("localhost:11434").foregroundStyle(.secondary)
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button("Refresh Models") { Task { await refresh() } }.disabled(loading)
        }
        Toggle("Allow cleanup metadata to be sent through Ollama", isOn: $consent)
        Text("Models marked Cloud send prompts through Ollama to a remote provider. Local models run on this Mac. DiskSage sends no paths or project names and never downloads models automatically.")
            .font(.caption).foregroundStyle(.secondary)
        if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        if !loading, error == nil, models.isEmpty {
            Text("No text models found. Add a model in Ollama, then refresh this list.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Color.clear.frame(height: 0).task { await refresh() }
    }

    @MainActor private func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            models = try await OllamaAdvisor().availableModels()
            error = nil
        } catch {
            models = []
            self.error = error.localizedDescription
        }
    }
}
