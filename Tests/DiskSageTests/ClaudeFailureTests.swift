import Foundation
import Testing
@testable import DiskSage

struct ClaudeFailureTests {
    enum Failure: CaseIterable {
        case quota, authentication, unknown
        var detail: String {
            switch self {
            case .quota: "You've hit your weekly limit."
            case .authentication: "Not logged in. Authentication required."
            case .unknown: "Unexpected failure /Users/private/project token=secret-value"
            }
        }
        var expected: String {
            switch self {
            case .quota: "Claude usage limit reached. Wait for the limit to reset or choose another agent."
            case .authentication: "Claude authentication is missing or expired. Run ‘claude auth login’ in Terminal, then try again."
            case .unknown: "Claude exited with status 1. Check Claude Code for details or choose another agent."
            }
        }
    }

    @Test(arguments: Failure.allCases)
    func nonzeroProcessExitPreservesTheFailureCategoryWithoutExposingRawOutput(failure: Failure) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "DiskSage-ClaudeFailure-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "claude")
        let body = try JSONSerialization.data(withJSONObject: ["subtype": "success", "is_error": true,
            "terminal_reason": "api_error", "result": failure.detail])
        let script = "#!/bin/sh\ncat <<'DISKSAGE_RESPONSE'\n\(String(decoding: body, as: UTF8.self))\nDISKSAGE_RESPONSE\nexit 1\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let candidate = CleanupCandidate(url: URL(fileURLWithPath: "/fixture/build"), name: "Fixture",
            category: .build, size: 4096, risk: .low, reason: "Generated output")
        do {
            _ = try await ClaudeAdvisor().recommend(candidates: [candidate], executablePath: executable.path, model: "")
            Issue.record("A failing CLI must not produce advice")
        } catch {
            #expect(error.localizedDescription == failure.expected)
            #expect(!error.localizedDescription.contains("secret-value"))
            #expect(!error.localizedDescription.contains("/Users/private"))
        }
    }

    @Test func anErrorEnvelopeOnSuccessfulProcessExitStillExplainsQuota() {
        let data = Data(#"{"subtype":"success","is_error":true,"result":"You've hit your weekly limit."}"#.utf8)
        do { _ = try ClaudeAdvisor.decode(data); Issue.record("Expected quota failure") }
        catch { #expect(error.localizedDescription == Failure.quota.expected) }
    }
}
