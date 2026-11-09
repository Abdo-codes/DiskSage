import Foundation
import Testing
@testable import DiskSage

struct XcodeProjectBuildTests {
    let hash = "fsimadikzvgqalcrcjftffgsluzr"

    @Test func projectFolderNamesHaveA28LetterHash() {
        #expect(TemporaryBuildOutput.isXcodeProjectFolderName("KidColor-\(hash)"))
        #expect(TemporaryBuildOutput.isXcodeProjectFolderName("associate-app-native-wt-hig4-\(hash)"))
        #expect(!TemporaryBuildOutput.isXcodeProjectFolderName("ModuleCache.noindex"))
        #expect(!TemporaryBuildOutput.isXcodeProjectFolderName("wt-reflex"))
        #expect(!TemporaryBuildOutput.isXcodeProjectFolderName("-\(hash)"))
        #expect(!TemporaryBuildOutput.isXcodeProjectFolderName("App-\(hash.uppercased())"))
    }

    @Test func idleProjectFolderIsOfferedWholeAndSharedCachesAreNot() throws {
        let f = try TemporaryBuildFixture(); defer { f.remove() }
        let root = "Library/Developer/Xcode/DerivedData"
        try f.write("\(root)/App-\(hash)/info.plist")
        try f.write("\(root)/App-\(hash)/Build/Intermediates.noindex/a.o")
        try f.write("\(root)/ModuleCache.noindex/x.pcm")
        try f.write("\(root)/NoPlist-\(hash)/Build/a.o")
        let project = CleanupPath.fileURL(f.base.appending(path: "\(root)/App-\(hash)"))
        #expect(TemporaryBuildOutput.kind(of: project, home: f.base) == .xcodeProjectBuild)
        #expect(TemporaryBuildOutput.kind(of: f.base.appending(path: "\(root)/ModuleCache.noindex"), home: f.base) == nil)
        #expect(TemporaryBuildOutput.kind(of: f.base.appending(path: "\(root)/NoPlist-\(hash)"), home: f.base) == nil)
        #expect(TemporaryBuildInspector.inspect(project, activity: .idle, now: f.later(hours: 12), home: f.base) == nil)
        let review = try #require(TemporaryBuildInspector.inspect(project, activity: .idle, now: f.later(hours: 30), home: f.base))
        #expect(review.risk == .medium)
        let routine = try #require(TemporaryBuildInspector.inspect(project, activity: .idle, now: f.later(hours: 80), home: f.base))
        #expect(routine.risk == .low)
        try SafetyPolicy(home: f.base, now: f.later(hours: 80)).validate(routine)
        // A build that names the folder keeps it.
        let busy = CleanupActivity(paths: [project.path])
        #expect(TemporaryBuildInspector.inspect(project, activity: busy, now: f.later(hours: 80), home: f.base) == nil)
    }

    @Test func compiledFilesRuleHandsIdleProjectsToTheWholeFolderRule() throws {
        let f = try GeneratedCleanupFixture(relative: "Library/Developer/Xcode/DerivedData"); defer { f.remove() }
        try f.write("App-\(hash)/Build/Intermediates.noindex/a.o")
        try f.write("wt-reflex/Build/Intermediates.noindex/b.o")
        // Two hours later: the project changed within a day, so its compiled files stay with this rule.
        let soon = try GeneratedFileInventory.read(f.root, rule: .buildArtifacts, cutoff: Date().addingTimeInterval(7_200),
                                                   activity: .perChild)
        #expect(soon.entries.map(\.path) == ["App-\(hash)/Build/Intermediates.noindex/a.o",
                                             "wt-reflex/Build/Intermediates.noindex/b.o"])
        // Two days later: the project folder goes to the whole-folder rule. Other folders stay.
        let later = try GeneratedFileInventory.read(f.root, rule: .buildArtifacts, cutoff: Date().addingTimeInterval(172_800),
                                                    activity: .perChild)
        #expect(later.entries.map(\.path) == ["wt-reflex/Build/Intermediates.noindex/b.o"])
    }
}
