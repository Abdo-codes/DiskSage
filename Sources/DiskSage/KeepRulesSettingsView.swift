import SwiftUI

/// Settings for `KeepRules`. DiskSage never offers or deletes what these rules keep.
struct KeepRulesSettingsView: View {
    @AppStorage(KeepRules.pathsKey) private var paths = ""
    @AppStorage(KeepRules.simulatorNamesKey) private var simulatorNames = ""

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Kept paths, one per line")
                TextEditor(text: $paths)
                    .font(.body.monospaced())
                    .frame(minHeight: 64)
                let invalid = KeepRules.invalidPaths(paths)
                if !invalid.isEmpty {
                    Text("Use absolute paths or paths that start with ~/. Ignored: \(invalid.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            TextField("Kept simulator names", text: $simulatorNames, prompt: Text("lane-*, coord-*"))
        } header: {
            Text("Keep")
        } footer: {
            Text("DiskSage never offers or deletes a kept path, anything inside it, or a folder that contains it. Simulators whose names match a pattern stay.")
        }
    }
}
