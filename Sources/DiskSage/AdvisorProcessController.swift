import Darwin
import Foundation

/// Cancellation is latched even when it arrives before the process starts.
final class AdvisorProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let terminationGrace: TimeInterval

    init(terminationGrace: TimeInterval = 3) { self.terminationGrace = terminationGrace }

    func launch(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        self.process = process
        try process.run()
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        cancelled = true
        let wasRunning = process?.isRunning == true
        if wasRunning { process?.terminate() }
        lock.unlock()
        guard wasRunning else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + terminationGrace) { [self] in
            lock.lock()
            defer { lock.unlock() }
            if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
