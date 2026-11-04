import Darwin
import Foundation
import Testing
@testable import DiskSage

struct AdvisorProcessControllerTests {
    @Test func cancellationEscalatesIfAChildIgnoresTermination() throws {
        let controller = AdvisorProcessController(terminationGrace: 0.05)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready', flush=True); time.sleep(30)"]
        process.standardOutput = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try controller.launch(process)
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let ready = output.fileHandleForReading.availableData
        try #require(String(decoding: ready, as: UTF8.self).contains("ready"))
        controller.terminate()
        #expect(finished.wait(timeout: .now() + 3) == .success)
        #expect(!process.isRunning)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
    }
}
