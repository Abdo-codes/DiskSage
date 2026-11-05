import AppKit
import SwiftUI

struct AboutView: View {
    var information = AppInformation()
    var icon = NSImage(named: NSImage.applicationIconName) ?? NSImage()

    var body: some View {
        Form {
            Section {
                AboutIdentity(information: information, icon: icon)
            }
            Section("Get started") {
                Text("Use DiskSage on its own, or connect Claude Code, Codex, or another MCP client. No skill package is required.")
                Button("Connect an agent…", systemImage: "point.3.connected.trianglepath.dotted") {
                    NotificationCenter.default.post(name: .diskSageOpenWindow, object: "onboarding")
                }
            }
            AboutResources()
            Section("Privacy & cleanup") {
                Text("Scanning and cleanup run on this Mac. Built-in advisors receive metadata only with your consent. Connected MCP clients can review paths, schedules, and logs under your permissions.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Cleanup permanently deletes files instead of moving them to the Trash.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(16)
    }
}

private struct AboutIdentity: View {
    let information: AppInformation
    let icon: NSImage
    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: icon)
                .resizable().interpolation(.high).frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("DiskSage").font(.title.weight(.semibold))
                Text("Developer disk cleanup for macOS").foregroundStyle(.secondary)
                Text("Version \(information.displayVersion)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        LabeledContent("Developer", value: "Abdo Eaita")
        LabeledContent("License", value: "MIT")
    }
}

private struct AboutResources: View {
    var body: some View {
        Section("Resources") {
            Link(destination: AppInformation.documentation) { Label("Documentation", systemImage: "book") }
            Link(destination: AppInformation.issues) { Label("Report an issue", systemImage: "bubble.left.and.exclamationmark.bubble.right") }
            Link(destination: AppInformation.repository) { Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
            Link(destination: AppInformation.license) { Label("Read the MIT license", systemImage: "doc.text") }
        }
    }
}
