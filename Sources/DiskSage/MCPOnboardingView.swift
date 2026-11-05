import SwiftUI

struct MCPOnboardingView: View {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome, connect, verify
        var id: Self { self }
        var title: LocalizedStringResource {
            switch self { case .welcome: "Welcome"; case .connect: "Connect"; case .verify: "Verify" }
        }
    }
    let model: AppModel
    let instructions: MCPConnectionInstructions
    let finish: () -> Void
    let openGeneralSettings: () -> Void
    @State private var step: Step
    @State private var verificationStarted = Date()

    init(model: AppModel, initialStep: Step = .welcome, instructions: MCPConnectionInstructions = .current, finish: @escaping () -> Void,
         openGeneralSettings: @escaping () -> Void) {
        self.model = model
        self.instructions = instructions
        self.finish = finish
        self.openGeneralSettings = openGeneralSettings
        _step = State(initialValue: initialStep)
    }
    var body: some View {
        VStack(spacing: 0) {
            OnboardingHeader(step: step)
            Divider()
            switch step {
            case .welcome: OnboardingWelcome(openGeneralSettings: openGeneralSettings)
            case .connect:
                Form { MCPConnectionSetupView(instructions: instructions) }.formStyle(.grouped).padding(16)
            case .verify:
                MCPConnectionVerificationView(serverError: model.agentToolConnectionError,
                    lastContact: model.lastMCPContact, startedAt: verificationStarted)
            }
            Divider()
            HStack {
                Button("Skip for now", action: finish)
                Spacer()
                if step != .welcome {
                    Button("Back") { step = Step(rawValue: step.rawValue - 1)! }
                }
                Button(step == .verify ? "Done" : "Continue") {
                    if step == .verify { finish() }
                    else {
                        step = Step(rawValue: step.rawValue + 1)!
                        if step == .verify { verificationStarted = Date() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}

private struct OnboardingHeader: View {
    let step: MCPOnboardingView.Step
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to DiskSage").font(.title2.weight(.semibold))
            HStack(spacing: 20) {
                ForEach(MCPOnboardingView.Step.allCases) { item in
                    Label { Text(item.title) } icon: {
                        Image(systemName: item.rawValue < step.rawValue ? "checkmark.circle.fill" : "\(item.rawValue + 1).circle")
                    }
                    .foregroundStyle(item == step ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                Spacer()
            }
            .font(.callout)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OnboardingWelcome: View {
    let openGeneralSettings: () -> Void
    var body: some View {
        Form {
            Section("Clean with a clear record") {
                Label("Find generated build files and caches", systemImage: "externaldrive")
                Label("Review cleanup or set folder schedules", systemImage: "calendar.badge.clock")
                Label("See what was removed and when", systemImage: "clock.arrow.circlepath")
                Text("Cleanup permanently deletes files. Review low-disk automation and its threshold in General & Safety.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Review cleanup settings…", action: openGeneralSettings)
            }
            Section("An agent is optional") {
                Text("Connect Claude Code, Codex, or another MCP client to manage DiskSage from a conversation. The app handles scanning, scheduling, safety checks, and logging.")
                Text("No model account or skill package is needed to use DiskSage on its own. You can reopen this guide from Settings → About.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).padding(16)
    }
}
