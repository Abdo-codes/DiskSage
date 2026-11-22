import Foundation
import Testing
@testable import DiskSage

struct SwiftPMCheckoutGuardTests {
    private let hash = "fsimadikzvgqalcrcjftffgsluzr"

    private func writeInfoPlist(at folder: URL, workspacePath: String) throws {
        let plist: [String: Any] = ["WorkspacePath": workspacePath]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appending(path: "info.plist"))
    }

    @Test func orphanedDerivedDataWorkspaceIsOfferedAtLowRisk() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let missingWorkspace = f.base.appending(path: "DeletedApp/App.xcodeproj").path
        let folder = f.base.appending(path: "Library/Developer/Xcode/DerivedData/DeletedApp-\(hash)")
        try writeInfoPlist(at: folder, workspacePath: missingWorkspace)
        try f.write("Library/Developer/Xcode/DerivedData/DeletedApp-\(hash)/Build/Intermediates.noindex/a.o")

        #expect(XcodeWorkspaceStatus.check(derivedDataFolder: folder) == .missing(missingWorkspace))
        // After 2 hours idle, an orphaned workspace is already low risk (active workspaces require 3 days).
        let candidate = try #require(TemporaryBuildInspector.inspect(folder, activity: .idle, now: f.later(hours: 2), home: f.base))
        #expect(candidate.risk == .low)
        #expect(candidate.reason.contains("workspace no longer exists"))

        // If the workspace reappears before deletion, pre-deletion verification refuses it.
        _ = try f.folder("DeletedApp/App.xcodeproj")
        #expect(XcodeWorkspaceStatus.check(derivedDataFolder: folder) == .present(missingWorkspace))
        #expect(throws: (any Error).self) {
            try TemporaryBuildInspector.verifyBeforeDeletion(candidate, activity: .idle, now: f.later(hours: 2), home: f.base)
        }
    }

    @Test func unmountedExternalVolumeIsNotTreatedAsOrphaned() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let folder = f.base.appending(path: "Library/Developer/Xcode/DerivedData/ExternalApp-\(hash)")
        try writeInfoPlist(at: folder, workspacePath: "/Volumes/DiskSageMissingVolume-\(UUID().uuidString)/App.xcodeproj")
        try f.write("Library/Developer/Xcode/DerivedData/ExternalApp-\(hash)/Build/a.o")

        #expect(XcodeWorkspaceStatus.check(derivedDataFolder: folder) == .unknown)
        // Not orphaned: stays excluded at 2 hours idle.
        #expect(TemporaryBuildInspector.inspect(folder, activity: .idle, now: f.later(hours: 2), home: f.base) == nil)
    }

    @Test func dirtyOrLocalCommitSwiftPMCheckoutRefusesWholeFolderDeletion() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let derived = try f.derivedData("app-derived")
        let (_, checkout) = try f.swiftPMClone(in: "app-derived/SourcePackages", name: "dep")

        // Clean clone passes both scan and pre-deletion checks.
        let clean = try #require(TemporaryBuildInspector.inspect(derived, activity: .idle, now: f.later(hours: 30), home: f.home))
        try TemporaryBuildInspector.verifyBeforeDeletion(clean, activity: .idle, now: f.later(hours: 30), home: f.home)

        // Uncommitted edit inside the dependency checkout blocks both scan and pre-deletion.
        try Data("edited\n".utf8).write(to: checkout.appending(path: "Package.swift"))
        #expect(TemporaryBuildInspector.inspect(derived, activity: .idle, now: f.later(hours: 30), home: f.home) == nil)
        #expect(throws: (any Error).self) {
            try TemporaryBuildInspector.verifyBeforeDeletion(clean, activity: .idle, now: f.later(hours: 30), home: f.home)
        }

        // Committing locally (not on origin) still blocks deletion.
        let git = WorktreeGitProcess()
        _ = try git.run(checkout.path, ["config", "user.name", "Test"])
        _ = try git.run(checkout.path, ["config", "user.email", "test@example.com"])
        _ = try git.run(checkout.path, ["add", "Package.swift"])
        _ = try git.run(checkout.path, ["commit", "-m", "Local work"])
        #expect(TemporaryBuildInspector.inspect(derived, activity: .idle, now: f.later(hours: 30), home: f.home) == nil)
    }

    @Test func stashedSwiftPMCheckoutAndLinkedGitDirAreRefused() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let derived = try f.derivedData("stash-derived")
        let (_, checkout) = try f.swiftPMClone(in: "stash-derived/SourcePackages", name: "dep")
        let git = WorktreeGitProcess()
        _ = try git.run(checkout.path, ["config", "user.name", "Test"])
        _ = try git.run(checkout.path, ["config", "user.email", "test@example.com"])
        try Data("wip\n".utf8).write(to: checkout.appending(path: "Package.swift"))
        _ = try git.run(checkout.path, ["stash", "push", "-m", "wip"])
        #expect(TemporaryBuildInspector.inspect(derived, activity: .idle, now: f.later(hours: 30), home: f.home) == nil)

        // FolderSurvey detects linked-worktree gitdirs (HEAD beside commondir) even without objects/.
        let linkedDir = try f.folder("linked-holder")
        try f.write("linked-holder/meta/HEAD")
        try f.write("linked-holder/meta/commondir")
        #expect(throws: (any Error).self) { try FolderSurvey.read(linkedDir, gitAllowedUnder: []) }
    }
}
