import AppKit
import SwiftUI

/// Settings section for editing `~/.config/disksage/rules.json` project-cache quiet hours,
/// extra project roots, additional cache names, and skipped folder names.
struct ProjectCacheRulesSettingsView: View {
    @State private var quietHours: Int = Int(ProjectCacheRules.default.quietHours)
    @State private var extraRootsText = ""
    @State private var extraNamesText = ""
    @State private var extraSkipText = ""
    @State private var preservedConfig = ProjectCacheRulesLoader.UserConfig()
    @State private var loadError: String?
    @State private var statusMessage: String?
    @State private var isErrorStatus = false
    @State private var isLoaded = false

    private var extraRootsList: [String] {
        extraRootsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var extraNamesList: [String] {
        parseCommaList(extraNamesText)
    }

    private var extraSkipList: [String] {
        parseCommaList(extraSkipText)
    }

    private var invalidRoots: [String] {
        ProjectCacheRulesLoader.invalidExtraRoots(extraRootsList)
    }

    private var invalidNames: [String] {
        extraNamesList.filter { !ProjectCacheRules.isValidRuleName($0) }
    }

    private var invalidSkips: [String] {
        extraSkipList.filter { !ProjectCacheRulesLoader.isValidSkipName($0) }
    }

    private var hasValidationError: Bool {
        !invalidRoots.isEmpty || !invalidNames.isEmpty || !invalidSkips.isEmpty
    }

    var body: some View {
        Section {
            if let loadError {
                Label("Could not load existing rules.json: \(loadError)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Stepper("Project quiet period: \(quietHours) \(quietHours == 1 ? "hour" : "hours")",
                    value: $quietHours, in: 1...168)

            VStack(alignment: .leading, spacing: 6) {
                Text("Extra project folders, one per line")
                TextEditor(text: $extraRootsText)
                    .font(.body.monospaced())
                    .frame(minHeight: 56)
                if !invalidRoots.isEmpty {
                    Text("Use folders under ~ (excluding ~/Library and symlinks): \(invalidRoots.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            TextField("Extra cache folder names", text: $extraNamesText, prompt: Text(".cache-build, out"))
            if !invalidNames.isEmpty {
                Text("Invalid cache names (VCS names and .. are refused): \(invalidNames.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            TextField("Additional skipped folder names", text: $extraSkipText, prompt: Text("third_party, archive"))
            if !invalidSkips.isEmpty {
                Text("Skip names must be single folder names without slashes: \(invalidSkips.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                Button("Save Rules", action: save)
                    .disabled(hasValidationError || loadError != nil)
                Button("Reveal rules.json", action: revealConfig)
                Button("Reset", action: resetDefaults)
                    .disabled(loadError != nil)
                Spacer()
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(isErrorStatus ? .red : .secondary)
                }
            }
        } header: {
            Text("Project Cache Rules")
        } footer: {
            Text("Saved to \(ProjectCacheRulesLoader.configURL().path). Built-in roots (~/Developer, ~/Documents/Codex, and mise-tracked projects) plus Git-ignore, zero-tracked-file, nested-Git, and Keep checks always remain enforced.")
        }
        .onAppear {
            guard !isLoaded else { return }
            isLoaded = true
            reload()
        }
    }

    private func reload() {
        let url = ProjectCacheRulesLoader.configURL()
        do {
            let config = try ProjectCacheRulesLoader.loadConfig(from: url)
            preservedConfig = config
            quietHours = Int((config.quietHours ?? ProjectCacheRules.default.quietHours).rounded())
            extraRootsText = (config.extraRoots ?? []).joined(separator: "\n")
            extraNamesText = (config.names ?? []).joined(separator: ", ")
            extraSkipText = (config.skip ?? []).joined(separator: ", ")
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() {
        var updated = preservedConfig
        updated.quietHours = Double(quietHours) == ProjectCacheRules.default.quietHours ? nil : Double(quietHours)
        updated.extraRoots = extraRootsList.isEmpty ? nil : extraRootsList
        updated.names = extraNamesList.isEmpty ? nil : extraNamesList
        updated.skip = extraSkipList.isEmpty ? nil : extraSkipList
        do {
            try ProjectCacheRulesLoader.save(updated)
            preservedConfig = updated
            statusMessage = "Saved."
            isErrorStatus = false
        } catch {
            statusMessage = error.localizedDescription
            isErrorStatus = true
        }
    }

    private func resetDefaults() {
        quietHours = Int(ProjectCacheRules.default.quietHours)
        extraRootsText = ""
        extraNamesText = ""
        extraSkipText = ""
        save()
    }

    private func revealConfig() {
        let url = ProjectCacheRulesLoader.configURL()
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let folder = url.deletingLastPathComponent()
            NSWorkspace.shared.open(FileManager.default.fileExists(atPath: folder.path)
                ? folder : FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    private func parseCommaList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
