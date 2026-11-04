import AppKit
import SwiftUI

struct AgentReviewButton: View {
    let model: AppModel
    var compact = false
    @AppStorage("agentProvider") private var provider: AgentProvider = .codex
    @AppStorage("codexExecutablePath") private var codexPath = ""
    @AppStorage("codexModel") private var codexModel = ""
    @AppStorage("claudeExecutablePath") private var claudePath = ""
    @AppStorage("claudeModel") private var claudeModel = ""
    @AppStorage("agentMetadataConsent") private var codexConsent = false
    @AppStorage("claudeMetadataConsent") private var claudeConsent = false
    @AppStorage("ollamaModel") private var ollamaModel = ""
    @AppStorage("ollamaMetadataConsent") private var ollamaConsent = false
    @AppStorage("builtInAgentCleanupEnabled") private var cleanupEnabled = false
    @AppStorage("agentCleanupPolicy") private var cleanupPolicy = AgentCleanupPolicy.confirm.rawValue
    @State private var pendingRequest: AgentConfiguration?
    @State private var showsConsent = false
    @State private var readiness: AgentReadiness?
    @State private var checkedConfiguration: AgentConfiguration?
    @State private var refreshCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if compact {
                actionButton.modifier(DashboardActionStyle()).controlSize(.large)
                Text(policyDescription).font(.caption).foregroundStyle(DashboardTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                actionButton
            }
            AgentReadinessView(readiness: currentReadiness, provider: provider, compact: compact)
        }
        .task(id: ReadinessRequest(configuration: configuration, refreshCount: refreshCount)) {
            let request = configuration
            readiness = nil
            checkedConfiguration = nil
            let result = await AgentReadinessClient().check(request)
            guard !Task.isCancelled else { return }
            readiness = result
            checkedConfiguration = request
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshCount += 1
        }
    }

    private var actionButton: some View {
        Button {
            let request = configuration
            if hasConsent(for: request.provider) {
                model.askAgent(configuration: request)
            } else {
                pendingRequest = request
                showsConsent = true
            }
        } label: {
            Label { Text(buttonTitle) } icon: { Image(systemName: "sparkles") }
                .frame(maxWidth: compact ? .infinity : nil)
        }
        .help(allowsCleanup ? "Ask \(provider.title) to review metadata and request low-risk cleanup" : "Ask \(provider.title) to review metadata")
        .accessibilityHint(Text(policyDescription))
        .disabled(model.candidates.isEmpty || model.isBusy || currentReadiness?.isReady != true)
        .alert("Send cleanup metadata to \(pendingRequest?.provider.title ?? provider.title)?",
               isPresented: $showsConsent, presenting: pendingRequest) { request in
            Button("Allow and Continue") {
                switch request.provider {
                case .codex: codexConsent = true
                case .claude: claudeConsent = true
                case .apple: break
                case .ollama: ollamaConsent = true
                }
                model.askAgent(configuration: request)
                pendingRequest = nil
            }
            Button("Cancel", role: .cancel) { pendingRequest = nil }
        } message: { request in
            if request.provider == .ollama {
                Text("DiskSage sends category, size, risk, generic reasons, and random candidate IDs to Ollama on localhost. Selected model: \(request.model). Cloud models forward this metadata to a remote provider. Paths and project names are excluded.")
            } else {
                Text("DiskSage sends category, size, risk, generic reasons, and random candidate IDs through your signed-in \(request.provider.title) CLI. Paths and project names are excluded. The provider may process this metadata remotely.")
            }
        }
    }

    private var currentReadiness: AgentReadiness? { checkedConfiguration == configuration ? readiness : nil }
    private struct ReadinessRequest: Equatable {
        let configuration: AgentConfiguration
        let refreshCount: Int
    }

    private func hasConsent(for provider: AgentProvider) -> Bool {
        switch provider {
        case .apple: true
        case .codex: codexConsent
        case .claude: claudeConsent
        case .ollama: ollamaConsent
        }
    }

    private var buttonTitle: LocalizedStringResource {
        if allowsCleanup {
            if cleanupPolicy == AgentCleanupPolicy.automaticLowRisk.rawValue {
                return compact ? "Review & Clean with \(provider.title)" : "Ask \(provider.title) to Review & Clean"
            }
            return "Review with \(provider.title)…"
        }
        return compact ? "Review with \(provider.title)" : "Ask \(provider.title)"
    }

    private var policyDescription: LocalizedStringResource {
        guard allowsCleanup else { return "Metadata review only." }
        return cleanupPolicy == AgentCleanupPolicy.automaticLowRisk.rawValue
            ? "Can delete low-risk items without confirmation."
            : "Low-risk cleanup requires your confirmation."
    }

    private var allowsCleanup: Bool { cleanupEnabled && cleanupPolicy != AgentCleanupPolicy.disabled.rawValue }

    private var configuration: AgentConfiguration {
        switch provider {
        case .codex: AgentConfiguration(provider: provider, executablePath: codexPath, model: codexModel, allowsCleanupRequests: allowsCleanup)
        case .claude: AgentConfiguration(provider: provider, executablePath: claudePath, model: claudeModel, allowsCleanupRequests: allowsCleanup)
        case .apple: AgentConfiguration(provider: provider, allowsCleanupRequests: allowsCleanup)
        case .ollama: AgentConfiguration(provider: provider, model: ollamaModel, allowsCleanupRequests: allowsCleanup)
        }
    }
}
