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

    @Test func compiledFilesRuleHandsOnlyAcceptedProjectsToTheWholeFolderRule() throws {
        let f = try GeneratedCleanupFixture(relative: "Library/Developer/Xcode/DerivedData"); defer { f.remove() }
        try f.write("App-\(hash)/info.plist")
        try f.write("App-\(hash)/Build/Intermediates.noindex/a.o")
        try f.write("NoPlist-\(hash)/Build/Intermediates.noindex/c.o")
        try f.write("wt-reflex/Build/Intermediates.noindex/b.o")
        func read(hoursLater: Double, activity: CleanupActivity = .idle) throws -> [String] {
            let cutoff = Date().addingTimeInterval(hoursLater * 3_600)
            return try GeneratedFileInventory.read(f.root, rule: .buildArtifacts, cutoff: cutoff, activity: .perChild,
                handsOff: GeneratedFileDeleter.wholeFolderRule(activity: activity, cutoff: cutoff, home: f.home)).entries.map(\.path)
        }
        let all = ["App-\(hash)/Build/Intermediates.noindex/a.o", "NoPlist-\(hash)/Build/Intermediates.noindex/c.o",
                   "wt-reflex/Build/Intermediates.noindex/b.o"]
        // Two hours later: the project changed within a day, so its compiled files stay with this rule.
        #expect(try read(hoursLater: 2) == all)
        // Two days later: only the project that the whole-folder rule accepts leaves this rule.
        #expect(try read(hoursLater: 48) == Array(all.dropFirst()))
        // A build that uses the project keeps it out of the whole-folder rule, so its files stay here.
        let project = f.root.appending(path: "App-\(hash)").path
        #expect(try read(hoursLater: 48, activity: CleanupActivity(paths: [project])) == all)
    }
}
