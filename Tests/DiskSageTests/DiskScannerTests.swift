import Foundation
import Testing
@testable import DiskSage

struct DiskScannerTests {
    @Test
    func everyScannedCandidatePassesDeletionPolicy() async throws {
        let candidates = await DiskScanner().scan()
        let policy = SafetyPolicy()

        for candidate in candidates {
            try policy.validate(candidate)
        }
    }

    @Test
    func scannerNeverOffersItsOwnExecutableTree() async throws {
        let executable = try #require(Bundle.main.executableURL?.standardizedFileURL)
        let candidates = await DiskScanner().scan()

        #expect(candidates.allSatisfy { candidate in
            !executable.path.hasPrefix(candidate.url.standardizedFileURL.path + "/")
        })
    }
}
