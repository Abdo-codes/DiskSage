import SwiftUI

struct ScheduleSettingsView: View {
    let model: AppModel
    @State private var editor: Editor?
    @State private var removal: CleanupSchedule?

    private struct Editor: Identifiable {
        let id = UUID()
        var schedule: CleanupSchedule?
    }

    var body: some View {
        Form {
            Section {
                Text("Choose folders and cleanup times. Schedules run independently of the low-disk threshold.")
                Text("DiskSage must be running. Missed runs are picked up once after launch or wake, when other cleanup finishes. Times use this Mac’s time zone.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Add schedule…", systemImage: "plus") { editor = Editor() }
                    .disabled(!model.schedulesLoaded)
            } header: { Text("Scheduled cleanup") }

            if let error = model.scheduleError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Button("Reload schedules") {
                        model.store.send(.stopScheduling)
                        model.store.send(.startScheduling)
                    }
                }
            }

            if model.schedules.isEmpty {
                Section {
                    ContentUnavailableView("No schedules yet", systemImage: "calendar.badge.clock",
                        description: Text("Start with a generated build or cache folder. Other folders require explicit authorization."))
                }
            } else {
                ForEach(model.schedules) { schedule in
                    Section {
                        ScheduleRow(schedule: schedule,
                            isRunning: model.activeSchedule?.schedule.id == schedule.id,
                            setEnabled: { model.store.send(.setScheduleEnabled(schedule.id, $0)) },
                            edit: { editor = Editor(schedule: schedule) },
                            remove: { removal = schedule })
                            .disabled(!model.schedulesLoaded)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .sheet(item: $editor) { item in
            ScheduleEditorView(existing: item.schedule, candidates: model.lowRiskCandidates) {
                model.store.send(.saveSchedule($0))
                if model.scheduleError == nil { editor = nil }
                return model.scheduleError
            }
        }
        .confirmationDialog("Remove this schedule?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("Remove schedule", role: .destructive) {
                if let removal { model.store.send(.removeSchedule(removal.id)) }
                removal = nil
            }
        } message: { Text("This removes the schedule. It does not delete any files.") }
    }
}

private struct ScheduleRow: View {
    let schedule: CleanupSchedule
    let isRunning: Bool
    let setEnabled: (Bool) -> Void
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { schedule.isEnabled }, set: setEnabled)) {
                Label(schedule.folder.lastPathComponent, systemImage: "folder")
                    .font(.headline)
            }
            .accessibilityLabel("Enable schedule for \(schedule.folder.lastPathComponent)")
            .help("Pausing stops future runs. A deletion that has already started will finish.")
            Text(schedule.folder.path).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(schedule.frequency.title)
                Text("·")
                Text(schedule.scope.title)
            }.font(.caption)
            if isRunning { Label("Cleanup in progress", systemImage: "clock.arrow.circlepath") }
            else if !schedule.isEnabled { Text("Paused").foregroundStyle(.secondary) }
            else if let next = schedule.nextRun {
                LabeledContent("Next run") { Text(next, format: .dateTime.weekday().month().day().hour().minute()) }
            } else { Text("No upcoming run").foregroundStyle(.secondary) }
            if let result = schedule.lastResult {
                Text(result).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let last = schedule.lastRun {
                    Text("Last attempt: \(last, format: .dateTime.month().day().hour().minute())")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit…", action: edit)
                Button("Remove…", role: .destructive, action: remove)
            }
        }
        .padding(.vertical, 4)
    }
}
