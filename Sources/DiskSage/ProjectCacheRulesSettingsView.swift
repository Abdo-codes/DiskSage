import AppKit
import SwiftUI

/// Settings section for editing `~/.config/disksage/rules.json` project-cache quiet hours,
/// extra project roots, additional cache names, and skipped folder names.
struct ProjectCacheRulesSettingsView: View {
    @State private var quietHours: Int = Int(ProjectCacheRules.default.quietHours)
    @State private var extraRootsText = ""
    @State private var extraNamesText = ""
    @State private var extraSkipText = ""
    @State private var loadedQuietHours: Int = Int(ProjectCacheRules.default.quietHours)
    @State private var loadedRootsText = ""
    @State private var loadedNamesText = ""
    @State private var loadedSkipText = ""
    @State private var loadedRawData: Data?
    @State private var preservedConfig = ProjectCacheRulesLoader.UserConfig()
    @State private var loadError: String?
    @State private var statusMessage: String?
    @State private var isErrorStatus = false
    @State private var isLoaded = false

    private var extraRootsList: [String] { ProjectCacheRulesLoader.parseLines(extraRootsText) }
    private var extraNamesList: [String] { ProjectCacheRulesLoader.parseLines(extraNamesText) }
    private var extraSkipList: [String] { ProjectCacheRulesLoader.parseLines(extraSkipText) }

    private var invalidRoots: [String] { ProjectCacheRulesLoader.invalidExtraRoots(extraRootsList) }
    private var invalidNames: [String] { extraNamesList.filter { !ProjectCacheRules.isValidRuleName($0) } }
    private var invalidSkips: [String] { extraSkipList.filter { !ProjectCacheRulesLoader.isValidSkipName($0) } }

    private var hasValidationError: Bool {
        !invalidRoots.isEmpty || !invalidNames.isEmpty || !invalidSkips.isEmpty
    }

    private var isDirty: Bool {
        quietHours != loadedQuietHours
            || extraRootsText != loadedRootsText
            || extraNamesText != loadedNamesText
            || extraSkipText != loadedSkipText
    }

    var body: some View {
        Section {
            if let loadError {
                Label("Could not load existing rules.json: \(loadError)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Stepper("Project quiet period: \(quietHours) \(quietHours == 1 ? "hour" : "hours")",
                    value: $quietHours, in: ProjectCacheRulesLoader.editableQuietHoursRange)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Extra project folders, one per line")
                    Spacer()
                    Button("Add Folder…", systemImage: "folder.badge.plus", action: addProjectFolders)
                }
                TextEditor(text: $extraRootsText)
                    .font(.body.monospaced())
                    .frame(minHeight: 52)
                if !invalidRoots.isEmpty {
                    Text("Use folders under ~ (excluding ~/Library and symlinks): \(invalidRoots.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Extra cache folder names, one per line")
                TextEditor(text: $extraNamesText)
                    .font(.body.monospaced())
                    .frame(minHeight: 44)
                if !invalidNames.isEmpty {
                    Text("Invalid cache names (VCS names and .. are refused): \(invalidNames.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Additional skipped folder names, one per line")
                TextEditor(text: $extraSkipText)
                    .font(.body.monospaced())
                    .frame(minHeight: 44)
                if !invalidSkips.isEmpty {
                    Text("Skip names must be single folder names without slashes: \(invalidSkips.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack(spacing: 10) {
                Button("Save Rules", action: save)
                    .disabled(hasValidationError || loadError != nil)
                Button("Reload", action: reloadFromButton)
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
            if !isLoaded || !isDirty {
                isLoaded = true
                reload()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .diskSageProjectCacheRulesChanged)) { _ in
            if isLoaded, !isDirty {
                reload()
            }
        }
    }

    private func reloadFromButton() {
        reload()
        if loadError == nil {
            statusMessage = "Reloaded."
            isErrorStatus = false
        }
    }

    private func reload() {
        let url = ProjectCacheRulesLoader.configURL()
        do {
            let snapshot = try ProjectCacheRulesLoader.loadConfigSnapshot(from: url)
            let config = snapshot.config
            let editableHours = try ProjectCacheRulesLoader.editableQuietHours(from: config)
            let rootsText = try ProjectCacheRulesLoader.editableLines(from: config.extraRoots, field: "extra_roots")
            let namesText = try ProjectCacheRulesLoader.editableLines(from: config.names, field: "names")
            let skipText = try ProjectCacheRulesLoader.editableLines(from: config.skip, field: "skip")
            preservedConfig = config
            loadedRawData = snapshot.rawData
            quietHours = editableHours
            loadedQuietHours = editableHours
            extraRootsText = rootsText
            extraNamesText = namesText
            extraSkipText = skipText
            loadedRootsText = rootsText
            loadedNamesText = namesText
            loadedSkipText = skipText
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() {
        var updated = preservedConfig
        updated.quietHours = Double(quietHours) == ProjectCacheRules.default.quietHours ? nil : Double(quietHours)
        if extraRootsText != loadedRootsText {
            updated.extraRoots = extraRootsList.isEmpty ? nil : extraRootsList
        }
        if extraNamesText != loadedNamesText {
            updated.names = extraNamesList.isEmpty ? nil : extraNamesList
        }
        if extraSkipText != loadedSkipText {
            updated.skip = extraSkipList.isEmpty ? nil : extraSkipList
        }
        do {
            let written = try ProjectCacheRulesLoader.save(updated, expectedExistingData: .some(loadedRawData))
            preservedConfig = updated
            loadedRawData = written
            loadedQuietHours = quietHours
            loadedRootsText = extraRootsText
            loadedNamesText = extraNamesText
            loadedSkipText = extraSkipText
            statusMessage = "Saved."
            isErrorStatus = false
            NotificationCenter.default.post(name: .diskSageProjectCacheRulesChanged, object: nil)
        } catch {
            statusMessage = error.localizedDescription
            isErrorStatus = true
        }
    }

    private func resetDefaults() {
        var updated = preservedConfig
        updated.quietHours = nil
        updated.extraRoots = nil
        updated.names = nil
        updated.skip = nil
        do {
            let written = try ProjectCacheRulesLoader.save(updated, expectedExistingData: .some(loadedRawData))
            preservedConfig = updated
            loadedRawData = written
            quietHours = Int(ProjectCacheRules.default.quietHours)
            loadedQuietHours = quietHours
            extraRootsText = ""
            extraNamesText = ""
            extraSkipText = ""
            loadedRootsText = ""
            loadedNamesText = ""
            loadedSkipText = ""
            statusMessage = "Reset to defaults."
            isErrorStatus = false
            NotificationCenter.default.post(name: .diskSageProjectCacheRulesChanged, object: nil)
        } catch {
            statusMessage = error.localizedDescription
            isErrorStatus = true
        }
    }

    private func addProjectFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Project Folder"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        var merged = extraRootsList
        var seenKeys = Set(merged.map { normalizedRootKey($0) })
        var rejected: [String] = []
        var addedCount = 0

        for url in panel.urls {
            let formatted = KeepRules.displayPath(url)
            guard KeepRules.canRepresent(url),
                  ProjectCacheRulesLoader.invalidExtraRoots([formatted]).isEmpty else {
                rejected.append(url.lastPathComponent)
                continue
            }
            let key = normalizedRootKey(formatted)
            guard seenKeys.insert(key).inserted else { continue }
            merged.append(formatted)
            addedCount += 1
        }

        if addedCount > 0 {
            extraRootsText = merged.joined(separator: "\n")
        }
        if !rejected.isEmpty {
            statusMessage = "Skipped invalid folder(s) (must be non-symlinked under ~, outside ~/Library): \(rejected.joined(separator: ", "))."
            isErrorStatus = true
        } else if addedCount > 0 {
            statusMessage = nil
            isErrorStatus = false
        }
    }

    private func normalizedRootKey(_ entry: String) -> String {
        let home = CleanupPath.fileURL(FileManager.default.homeDirectoryForCurrentUser).path
        let expanded = entry.hasPrefix("~/") ? home + entry.dropFirst(1) : entry
        return CleanupPath.fileURL(URL(fileURLWithPath: expanded)).path
            .precomposedStringWithCanonicalMapping.lowercased()
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
}
