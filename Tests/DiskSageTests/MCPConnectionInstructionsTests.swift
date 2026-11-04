import Foundation
import Testing
@testable import DiskSage

struct MCPConnectionInstructionsTests {
    @Test(arguments: ["/Applications/DiskSage.app/Contents/MacOS/DiskSage",
                      "/Applications/Abdo's Disk Sage.app/Contents/MacOS/DiskSage",
                      "/tmp/$(touch should-not-exist)`echo injection`/DiskSage"])
    func copyableCommandsPreserveTheExecutableAsOneLiteralArgument(path: String) throws {
        let instructions = MCPConnectionInstructions(executablePath: path)
        for command in [instructions.claudeCommand, instructions.codexCommand] {
            // A shell function prints argv instead of running or configuring either real agent.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "claude() { printf '%s\\n' \"$@\"; }; codex() { printf '%s\\n' \"$@\"; }; " + command]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let arguments = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").map(String.init)
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(Array(arguments.suffix(3)) == ["--", path, "--mcp"])
            #expect(arguments.starts(with: ["mcp", "add"]))
        }
    }
}
