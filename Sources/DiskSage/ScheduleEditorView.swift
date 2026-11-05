import AppKit
import SwiftUI

struct ScheduleEditorView: View {
    let existing: CleanupSchedule?
    let candidates: [CleanupCandidate]
    let save: (CleanupSchedule) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var value = CleanupSchedule(folder: URL(fileURLWithPath: "/"),
        folderIdentity: FileIdentity(device: 0, inode: 0))
    @State private var hasFolder = false
    @State private var error: String?
    @State private var confirmsContents = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(existing == nil ? "New cleanup schedule" : "Edit cleanup schedule",
                    systemImage: "calendar.badge.clock").font(.headline)
                Spacer()
            }.padding(20)
            Divider()
            Form {
                ScheduleFolderFields(value: $value, hasFolder: hasFolder, candidates: candidates,
                    chooseFolder: chooseFolder, useFolder: useFolder)
                ScheduleTimingFields(value: $value)
                Section {
                    Toggle("Enable schedule", isOn: $value.isEnabled)
                    if let next = value.nextOccurrence(after: .now) {
                        LabeledContent("Next run") { Text(next, format: .dateTime.month().day().hour().minute()) }
                    }
                    Text("DiskSage must be running. Missed runs execute once after launch or wake; a busy cleanup delays them.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save schedule", action: prepareSave)
                    .keyboardShortcut(.defaultAction).disabled(!hasFolder)
            }.padding(16)
        }
        .frame(width: 520, height: 600)
        .onAppear {
            if let existing { value = existing; hasFolder = true }
        }
        .alert("Authorize automatic deletion?", isPresented: $confirmsContents) {
            Button("Authorize folder", role: .destructive, action: persist)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("At each scheduled time, DiskSage will permanently delete every file and subfolder inside \(value.folder.path). Files do not go to the Trash.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose folder"
        panel.begin { response in
            if response == .OK, let folder = panel.url { useFolder(folder) }
        }
    }

    private func useFolder(_ url: URL) {
        do {
            let identity = try ScheduledFolderPolicy.identity(of: url)
            value.folder = CleanupPath.fileURL(url)
            value.folderIdentity = identity
            hasFolder = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func prepareSave() {
        do {
            try ScheduledFolderPolicy.validate(value)
            guard !value.isEnabled || value.nextOccurrence(after: .now) != nil else {
                throw FeatureFailure(message: "Choose a future cleanup time.")
            }
            error = nil
            if value.scope == .folderContents && !(existing?.hasSameAuthorization(as: value) ?? false) {
                confirmsContents = true
            } else { persist() }
        } catch { self.error = error.localizedDescription }
    }

    private func persist() { error = save(value) }
}

private struct ScheduleTimingFields: View {
    @Binding var value: CleanupSchedule

    var body: some View {
        Section {
            Picker("Repeat", selection: $value.frequency) {
                ForEach(CleanupSchedule.Frequency.allCases, id: \.self) { frequency in
                    Text(frequency.title).tag(frequency)
                }
            }
            if value.frequency == .once {
                DatePicker("Run at", selection: $value.oneTimeDate, in: Date.now...,
                    displayedComponents: [.date, .hourAndMinute])
            } else {
                DatePicker("Time", selection: Binding(get: {
                    Calendar.current.date(from: DateComponents(hour: value.hour, minute: value.minute)) ?? .now
                }, set: {
                    value.hour = Calendar.current.component(.hour, from: $0)
                    value.minute = Calendar.current.component(.minute, from: $0)
                }), displayedComponents: .hourAndMinute)
                if value.frequency == .weekly {
                    Picker("Day", selection: $value.weekday) {
                        ForEach(1...7, id: \.self) { day in
                            Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                        }
                    }
                }
            }
        } header: { Text("Timing") }
    }
}

private struct ScheduleFolderFields: View {
    @Binding var value: CleanupSchedule
    let hasFolder: Bool
    let candidates: [CleanupCandidate]
    let chooseFolder: () -> Void
    let useFolder: (URL) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Folder").font(.headline)
            if hasFolder {
                Label(value.folder.lastPathComponent, systemImage: "folder")
                Text(value.folder.path).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Choose folder…", action: chooseFolder)
                Menu("Low-risk folders") {
                    Button("Xcode DerivedData") { useFolder(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Developer/Xcode/DerivedData", directoryHint: .isDirectory)) }
                    Button("npm package cache") { useFolder(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".npm/_cacache", directoryHint: .isDirectory)) }
                    ForEach(candidates) { candidate in
                        Button(candidate.name) { useFolder(candidate.url) }
                    }
                }
            }
            Picker("Remove", selection: $value[dynamicMember: \.scope]) {
                ForEach(CleanupSchedule.Scope.allCases, id: \.self) { scope in Text(scope.title).tag(scope) }
            }
            Text(value.scope == .lowRisk ?
                "Only recognized generated build and cache folders qualify. The selected folder stays in place." :
                "Every file and subfolder inside this folder will be permanently deleted. The selected folder stays in place.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
