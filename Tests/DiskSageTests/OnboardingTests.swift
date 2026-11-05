import ComposableArchitecture
import Foundation
import Testing
@testable import DiskSage

struct OnboardingTests {
    @Test func freshInstallShowsSetupUntilCompletedAndDoesNotChangeCleanupPreferences() throws {
        let name = "DiskSage.OnboardingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(MCPOnboardingPreferences.shouldAutoShow(defaults: defaults))
        #expect(defaults.object(forKey: "automaticCleanupEnabled") == nil)
        #expect(defaults.object(forKey: "agentCleanupPolicy") == nil)
        MCPOnboardingPreferences.complete(defaults: defaults)
        #expect(!MCPOnboardingPreferences.shouldAutoShow(defaults: defaults))
        #expect(defaults.object(forKey: "automaticCleanupEnabled") == nil)
        #expect(defaults.object(forKey: "agentCleanupPolicy") == nil)
    }

    @Test(arguments: ["settingsSelectedTab", "agentProvider", "automaticCleanupEnabled", "agentCleanupPolicy", "savedData"])
    func existingUsersAreNotInterruptedAndTheirPreferencesArePreserved(key: String) throws {
        let name = "DiskSage.OnboardingMigrationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        if key != "savedData" { defaults.set(false, forKey: key) }
        #expect(!MCPOnboardingPreferences.shouldAutoShow(defaults: defaults, hasExistingData: key == "savedData"))
        #expect(defaults.bool(forKey: MCPOnboardingPreferences.completionKey))
        if key != "savedData" { #expect(defaults.object(forKey: key) as? Bool == false) }
        defaults.set(false, forKey: MCPOnboardingPreferences.completionKey)
        #expect(MCPOnboardingPreferences.shouldAutoShow(defaults: defaults, hasExistingData: true))
    }

    @Test func verificationNeedsAFreshRequestAndAHealthyServer() {
        let start = Date(timeIntervalSince1970: 100)
        #expect(!MCPOnboardingPreferences.isVerified(since: start, lastContact: nil, serverError: nil))
        #expect(!MCPOnboardingPreferences.isVerified(since: start, lastContact: start.addingTimeInterval(-1), serverError: nil))
        #expect(MCPOnboardingPreferences.isVerified(since: start, lastContact: start, serverError: nil))
        #expect(!MCPOnboardingPreferences.isVerified(since: start, lastContact: start, serverError: "Server unavailable"))
    }

    @Test func aboutVersionUsesBundleMetadataWithoutInventingAReleaseVersion() {
        #expect(AppInformation(info: [:]).displayVersion == "Development build")
        #expect(AppInformation(info: ["CFBundleVersion": "12"]).displayVersion == "Development build (12)")
        #expect(AppInformation(info: ["CFBundleShortVersionString": "1.2.3"]).displayVersion == "1.2.3")
        #expect(AppInformation(info: ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "12"]).displayVersion == "1.2.3 (12)")
    }

    @MainActor @Test func onlyTheConnectionBoundaryRecordsClientContact() async {
        let model = AppModel(store: ManagementTestSupport.store())
        await model.store.send(.refreshDashboard).finish()
        #expect(model.lastMCPContact == nil)
        _ = model.handleAgentToolRequest(.init(action: .status))
        #expect(model.lastMCPContact == FeatureTestSupport.epoch)
    }
}
