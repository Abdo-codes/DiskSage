import Foundation
import Testing
@testable import DiskSage

struct WorktreeFixture {
    let root: URL
    let main: URL
    let checkout: URL
    let git = WorktreeGitProcess()
    init(format: String = "sha1") throws {
        root = URL(fileURLWithPath: "/private/tmp/disksage-git-test-\(UUID())")
        main = root.appending(path: "main")
        checkout = root.appending(path: "-feature with space\t日本\nline")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        _ = try git.run(main.path, ["init", "--object-format=\(format)", "-b", "main"])
        _ = try git.run(main.path, ["config", "user.name", "Fixture"])
        _ = try git.run(main.path, ["config", "user.email", "fixture@example.invalid"])
        _ = try git.run(main.path, ["config", "commit.gpgsign", "false"])
        try "tracked\n".write(to: main.appending(path: "file.txt"), atomically: true, encoding: .utf8)
        try ".build/\n.env\n".write(to: main.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        _ = try git.run(main.path, ["add", "."])
        _ = try git.run(main.path, ["commit", "-m", "fixture"])
        _ = try git.run(main.path, ["worktree", "add", "-b", "feature", "--", checkout.path])
    }
    var configuration: WorktreeConfiguration {
        WorktreeConfiguration(roots: [root.path], integrationRefs: [main.appending(path: ".git").path: "refs/heads/main"])
    }
    func item() throws -> GitWorktree {
        try #require(WorktreeParsing.records(git.run(main.path, ["worktree", "list", "--porcelain", "-z"]).data,
            common: main.appending(path: ".git").path).first { $0.path == checkout.path })
    }
    func inspect() throws -> WorktreeInspection { WorktreeInspector(checkActivity: false).inspect(try item(), configuration: configuration) }
    func remove(_ preview: WorktreePreview) throws -> [WorktreeResult] {
        let repository = WorktreeRepository(url: root.appending(path: "journal.json"))
        try repository.save(configuration)
        return WorktreeService(inspector: WorktreeInspector(checkActivity: false), repository: repository,
            logger: CleanupLogger(directory: root.appending(path: "logs"))).remove(preview)
    }
    func dispose() { try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized)
struct WorktreeNativeTests {
    @Test(arguments: ["sha1", "sha256"])
    func cleanCheckoutKeepsBranchAndCommonData(format: String) throws {
        let fixture = try WorktreeFixture(format: format); defer { fixture.dispose() }
        let item = try fixture.inspect()
        #expect(item.canRemove, "\(item.blockers)")
        #expect(item.merged == true && item.staged.isEmpty && item.untracked.isEmpty)
        #expect(item.worktree.path.contains("\n") && item.localCommits.count == 1)
        #expect(item.ahead == nil && item.upstream == nil)
        let oid = try fixture.git.text(fixture.main.path, ["rev-parse", "refs/heads/feature"])
        let result = try fixture.remove(WorktreePreview(items: [item]))
        #expect(result.count == 1 && result[0].succeeded, "\(result)")
        #expect(!FileManager.default.fileExists(atPath: fixture.checkout.path))
        #expect(try fixture.git.text(fixture.main.path, ["rev-parse", "refs/heads/feature"]) == oid)
        #expect(FileManager.default.fileExists(atPath: fixture.main.appending(path: ".git/objects").path))
    }

    @Test(arguments: ["modified", "staged", "untracked", "hidden", "skip", "locked", "operation", "nested", "private-config", "shallow", "intent-to-add", "sparse", "submodule"])
    func unsafeStatesNeverBecomeRemovable(kind: String) throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        let file = fixture.checkout.appending(path: "file.txt")
        switch kind {
        case "modified": try "changed".write(to: file, atomically: true, encoding: .utf8)
        case "staged":
            try "changed".write(to: file, atomically: true, encoding: .utf8)
            _ = try fixture.git.run(fixture.checkout.path, ["add", "file.txt"])
        case "untracked": try "keep".write(to: fixture.checkout.appending(path: "new\t\n.txt"), atomically: true, encoding: .utf8)
        case "hidden", "skip":
            _ = try fixture.git.run(fixture.checkout.path, ["update-index", kind == "hidden" ? "--assume-unchanged" : "--skip-worktree", "file.txt"])
            try "hidden edit".write(to: file, atomically: true, encoding: .utf8)
        case "locked": _ = try fixture.git.run(fixture.main.path, ["worktree", "lock", "--", fixture.checkout.path])
        case "operation", "private-config":
            let admin = try fixture.git.text(fixture.checkout.path, ["rev-parse", "--absolute-git-dir"])
            try "preserve".write(toFile: admin + (kind == "operation" ? "/MERGE_HEAD" : "/config.worktree"), atomically: true, encoding: .utf8)
        case "nested":
            let nested = fixture.checkout.appending(path: "nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            _ = try fixture.git.run(nested.path, ["init"])
        case "intent-to-add":
            try "new".write(to: fixture.checkout.appending(path: "intent"), atomically: true, encoding: .utf8)
            _ = try fixture.git.run(fixture.checkout.path, ["add", "--intent-to-add", "intent"])
        case "sparse": _ = try fixture.git.run(fixture.checkout.path, ["config", "core.sparseCheckout", "true"])
        case "submodule":
            let oid = try fixture.git.text(fixture.main.path, ["rev-parse", "HEAD"])
            _ = try fixture.git.run(fixture.checkout.path, ["update-index", "--add", "--cacheinfo", "160000,\(oid),submodule"])
        case "shallow":
            let oid = try fixture.git.text(fixture.main.path, ["rev-parse", "HEAD"])
            try oid.appending("\n").write(to: fixture.main.appending(path: ".git/shallow"), atomically: true, encoding: .utf8)
        default: break
        }
        let inspection = try fixture.inspect()
        #expect(!inspection.canRemove && (!inspection.blockers.isEmpty || inspection.requiresDiscardApproval), "\(kind): \(inspection)")
        let results = try fixture.remove(WorktreePreview(items: [inspection]))
        #expect(results.allSatisfy { !$0.succeeded })
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test(arguments: ["filter.fixture.clean", "core.fsmonitor"])
    func configuredExecutablesNeverRun(key: String) throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        let marker = fixture.root.appending(path: "helper-ran")
        _ = try fixture.git.run(fixture.main.path, ["config", key, "touch '\(marker.path)'"])
        let item = try fixture.inspect()
        if key.hasPrefix("filter") { #expect(!item.canRemove) }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test(arguments: ["edit", "lock", "branch", "path"])
    func changedEvidenceRefusesRemoval(change: String) throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        let preview = WorktreePreview(items: [try fixture.inspect()])
        switch change {
        case "edit": try "new changes".write(to: fixture.checkout.appending(path: "file.txt"), atomically: true, encoding: .utf8)
        case "lock": _ = try fixture.git.run(fixture.main.path, ["worktree", "lock", "--", fixture.checkout.path])
        case "branch": _ = try fixture.git.run(fixture.checkout.path, ["checkout", "-b", "other"])
        default:
            try FileManager.default.moveItem(at: fixture.checkout, to: fixture.root.appending(path: "moved"))
            try FileManager.default.createSymbolicLink(at: fixture.checkout, withDestinationURL: fixture.root.appending(path: "moved"))
        }
        #expect(try fixture.remove(preview).allSatisfy { !$0.succeeded })
        #expect(FileManager.default.fileExists(atPath: fixture.main.appending(path: ".git").path))
    }

    @Test func localCommitsAreRetainedButUnanchoredRecoveryHistoryBlocks() throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        _ = try fixture.git.run(fixture.checkout.path, ["commit", "--allow-empty", "-m", "local only"])
        var item = try fixture.inspect()
        #expect(item.canRemove && item.merged == false && item.localCommits.count == 2, "\(item.blockers)")
        _ = try fixture.git.run(fixture.checkout.path, ["reset", "--hard", "HEAD~1"])
        item = try fixture.inspect()
        #expect(!item.canRemove && item.discardReasons.contains { $0.contains("recovery history") }, "\(item.discardReasons)")
    }

    @Test func generatedIgnoredOutputRequiresExplicitApproval() throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        let output = fixture.checkout.appending(path: ".build")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data(repeating: 65, count: 8192).write(to: output.appending(path: "generated"))
        let item = try fixture.inspect()
        #expect(item.canRemove && item.ignored == [".build/"] && item.estimatedBytes > 0, "\(item.blockers)")
        #expect(try fixture.remove(WorktreePreview(items: [item], ignoredFilesApproved: true)).allSatisfy(\.succeeded))
    }

    @Test func schedulesCannotEraseCheckoutRootsOrTheirParents() throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        #expect(throws: (any Error).self) { try ScheduledFolderPolicy.identity(of: fixture.checkout) }
        #expect(throws: (any Error).self) { try ScheduledFolderPolicy.identity(of: fixture.root) }
        let generated = fixture.checkout.appending(path: ".build")
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        #expect(try ScheduledFolderPolicy.identity(of: generated).inode > 0)
    }
    @Test func knownProcessActivityAndMainCheckoutAreBlocked() throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]; process.currentDirectoryURL = fixture.checkout
        try process.run(); defer { process.terminate(); process.waitUntilExit() }
        let activity = try fixture.git.execute("/usr/sbin/lsof", ["-nP", "-a", "-p", String(process.processIdentifier), "-d", "cwd,txt", "-F0pn"])
        #expect(activity.code == 0)
        let item = WorktreeInspector(processPaths: try WorktreeActivity.paths(activity.data))
            .inspect(try fixture.item(), configuration: fixture.configuration)
        #expect(!item.canRemove && item.blockers.contains { $0.contains("using this checkout") }, "\(item.blockers)")
        let main = try #require(WorktreeParsing.records(fixture.git.run(fixture.main.path, ["worktree", "list", "--porcelain", "-z"]).data,
            common: fixture.main.appending(path: ".git").path).first)
        let mainInspection = WorktreeInspector(checkActivity: false).inspect(main, configuration: fixture.configuration)
        #expect(!mainInspection.canRemove && mainInspection.blockers.contains { $0.contains("Main checkout") })
    }

    @Test func protectionAndExplicitScopeAreEnforcedOnInspectionAndExecution() throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        let item = try fixture.item()
        var configuration = fixture.configuration
        configuration.protectedIDs.insert(item.id)
        #expect(!WorktreeInspector(checkActivity: false).inspect(item, configuration: configuration).canRemove)
        configuration = WorktreeConfiguration()
        #expect(!WorktreeInspector(checkActivity: false).inspect(item, configuration: configuration).canRemove)
    }

    @Test func cancelledQueueNeverStartsGitRemoval() throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        let preview = WorktreePreview(items: [try fixture.inspect()])
        WorktreeCancellation.shared.request(preview.id)
        let results = try fixture.remove(preview)
        #expect(results.count == 1 && !results[0].succeeded && results[0].message.contains("cancelled"))
        #expect(FileManager.default.fileExists(atPath: fixture.checkout.path))
    }

    @Test func redirectedWorktreeRootCannotCertifyAnotherFolderAsClean() throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        _ = try fixture.git.run(fixture.main.path, ["config", "extensions.worktreeConfig", "true"])
        _ = try fixture.git.run(fixture.checkout.path, ["config", "--worktree", "core.worktree", fixture.root.path])
        let item = try fixture.inspect()
        #expect(!item.canRemove && !item.blockers.isEmpty)
    }

    @Test func activityDecodesCLocaleUTF8BytesAndControlCharacters() throws {
        let data = Data(#"n/private/tmp/\xe6\x97\xa5\xe6\x9c\xac\tline\nname\\literal"#.utf8) + Data([0])
        #expect(try WorktreeActivity.paths(data) == ["/private/tmp/日本\tline\nname\\literal"])
        #expect(throws: FeatureFailure.self) { try WorktreeActivity.paths(Data(#"n/tmp/\qbad"#.utf8) + Data([0])) }
    }

    @Test(arguments: ["alternates", "symlink", "grafts"])
    func externalObjectStorageNeverCertifiesPreservation(kind: String) throws {
        let fixture = try WorktreeFixture(); defer { fixture.dispose() }
        let common = fixture.main.appending(path: ".git")
        switch kind {
        case "alternates":
            let generated = fixture.checkout.appending(path: ".build")
            try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
            let target = generated.appending(path: "borrowed-objects")
            try FileManager.default.moveItem(at: common.appending(path: "objects"), to: target)
            try FileManager.default.createDirectory(at: common.appending(path: "objects/info"), withIntermediateDirectories: true)
            try (String(reflecting: target.path) + "\n").write(to: common.appending(path: "objects/info/alternates"), atomically: true, encoding: .utf8)
        case "symlink":
            let oid = try fixture.git.text(fixture.main.path, ["rev-parse", "HEAD"])
            let original = common.appending(path: "objects/" + oid.prefix(2) + "/" + oid.dropFirst(2))
            let generated = fixture.checkout.appending(path: ".build")
            try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
            let target = generated.appending(path: "borrowed-commit-object")
            try FileManager.default.moveItem(at: original, to: target)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: target)
        default:
            let oid = try fixture.git.text(fixture.main.path, ["rev-parse", "HEAD"])
            try (oid + "\n").write(to: common.appending(path: "info/grafts"), atomically: true, encoding: .utf8)
        }
        if kind != "grafts" { _ = try fixture.git.run(fixture.checkout.path, ["cat-file", "-e", "HEAD^{commit}"]) }
        let item = try fixture.inspect()
        #expect(!item.canRemove && item.blockers.contains { $0.contains("Git object") || $0.contains("grafted history") })
        #expect(try fixture.remove(WorktreePreview(items: [item])).allSatisfy { !$0.succeeded })
        #expect(FileManager.default.fileExists(atPath: fixture.checkout.path))
    }

}
