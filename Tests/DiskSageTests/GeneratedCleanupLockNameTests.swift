import Foundation
import Testing
@testable import DiskSage

struct GeneratedCleanupLockNameTests {
    @Test(arguments: ["lock", "LOCK", "Package.lock", "yarn.lock", "build.lck", "a-lock", "a_lock", "a.lock.o",
                      ".lock", "lock.o", "lock-1.o", "lock2", "my.lockfile", "package-lockfile.json"])
    func lockNamesStayExcluded(name: String) throws {
        #expect(GeneratedCleanupPolicy.isLockFile(name))
        #expect(try !GeneratedCleanupPolicy.eligible(name: name, parents: [".build", "debug"], rootName: ".build",
            rule: .buildArtifacts, prefix: { Data() }, checksum: { "" }))
    }

    @Test(arguments: ["Block.o", "clock.swiftmodule", "NSLock-1a2b.o", "Deadlock.o", "unlocked.o", "Blocker.swiftdoc"])
    func unrelatedNamesAreEligible(name: String) throws {
        #expect(!GeneratedCleanupPolicy.isLockFile(name))
        #expect(try GeneratedCleanupPolicy.eligible(name: name, parents: [".build", "debug"], rootName: ".build",
            rule: .buildArtifacts, prefix: { Data() }, checksum: { "" }))
    }
}
