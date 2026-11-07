import Foundation
import Testing
@testable import DiskSage

@Suite(.serialized)
struct WorktreeConfigurationTests {
    @Test(arguments: ["extensionOnly", "standardLocal", "disabledSparse", "sharedRoot"])
    func ordinaryWorktreeConfigurationAllowsReviewAndRemoval(kind: String) throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        _ = try fixture.git.run(fixture.main.path, ["config", "extensions.worktreeConfig", "true"])
        switch kind {
        case "standardLocal":
            for (key, value) in [("core.bare", "false"), ("core.worktree", fixture.checkout.path), ("core.untrackedCache", "true")] {
                _ = try fixture.git.run(fixture.checkout.path, ["config", "--worktree", key, value])
            }
        case "disabledSparse":
            for key in ["core.sparseCheckout", "core.sparseCheckoutCone", "core.ignoreStat"] {
                _ = try fixture.git.run(fixture.checkout.path, ["config", "--worktree", key, "false"])
            }
        case "sharedRoot":
            _ = try fixture.git.run(fixture.main.path, ["config", "core.worktree", fixture.main.path])
            _ = try fixture.git.run(fixture.checkout.path, ["config", "--worktree", "core.worktree", fixture.checkout.path])
        default: break
        }
        let inspection = try fixture.inspect()
        #expect(inspection.canRemove, "\(inspection.blockers)")
        let results = try fixture.remove(WorktreePreview(items: [inspection]))
        #expect(results.count == 1 && results[0].succeeded, "\(results)")
        #expect(try fixture.git.text(fixture.main.path, ["rev-parse", "refs/heads/feature"]) == inspection.worktree.head)
    }

    @Test(arguments: ["privateSetting", "sparse", "promisor", "hiddenState"])
    func substantiveOrUnsafeSettingsStillBlock(kind: String) throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        _ = try fixture.git.run(fixture.main.path, ["config", "extensions.worktreeConfig", "true"])
        let pair: (String, String)
        switch kind {
        case "privateSetting": pair = ("branch.feature.description", "Keep this private worktree note")
        case "sparse": pair = ("core.sparseCheckout", "true")
        case "promisor": pair = ("remote.origin.promisor", "true")
        default: pair = ("core.ignoreStat", "true")
        }
        _ = try fixture.git.run(fixture.checkout.path, ["config", "--worktree", pair.0, pair.1])
        let inspection = try fixture.inspect()
        #expect(!inspection.canRemove && inspection.blockers.contains { $0.contains(pair.0.lowercased()) })
        #expect(FileManager.default.fileExists(atPath: fixture.checkout.path))
    }

    @Test func configChangesInvalidateApprovalEvenWhenBothConfigurationsAreSafe() throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        _ = try fixture.git.run(fixture.main.path, ["config", "extensions.worktreeConfig", "true"])
        _ = try fixture.git.run(fixture.checkout.path, ["config", "--worktree", "core.untrackedCache", "true"])
        let inspection = try fixture.inspect()
        #expect(inspection.canRemove)
        _ = try fixture.git.run(fixture.checkout.path, ["config", "--worktree", "core.untrackedCache", "false"])
        let results = try fixture.remove(WorktreePreview(items: [inspection]))
        #expect(results.count == 1 && !results[0].succeeded && results[0].message.contains("Evidence changed"))
    }

    @Test func primaryCheckoutsAreNotReportedAsUnsafeSharedStorage() throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        let rows = try WorktreeParsing.records(fixture.git.run(fixture.main.path, ["worktree", "list", "--porcelain", "-z"]).data,
            common: fixture.main.appending(path: ".git").path)
        let primary = rows.first { $0.main }
        let main = try #require(primary)
        let inspection = WorktreeInspector(checkActivity: false).inspect(main, configuration: fixture.configuration)
        #expect(!inspection.canRemove && inspection.label == "Primary checkout")
        #expect(!inspection.blockers.contains { $0.contains("Shared Git data is inside") })
    }

    @Test func standaloneClonesDoNotConsumeWorktreeInventoryLimit() throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        let clone = fixture.root.appending(path: "unrelated-clone")
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        _ = try fixture.git.run(clone.path, ["init"])
        let service = WorktreeService(inspector: WorktreeInspector(checkActivity: false))
        let inventory = try service.inventory(fixture.configuration)
        #expect(inventory.items.count == 2)
        #expect(inventory.items.contains { $0.worktree.path == fixture.checkout.path })
        #expect(!inventory.items.contains { $0.worktree.path == clone.path })
    }
}
