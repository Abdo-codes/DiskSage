import Foundation

/// Collects the output of one child process while another thread reads the pipe.
final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var storage = Data()

    var count: Int { lock.withLock { storage.count } }
    var data: Data { lock.withLock { storage } }

    func append(_ chunk: Data) { lock.withLock { storage.append(chunk) } }
    func finish() { finished.signal() }
    func wait(seconds: TimeInterval) -> Bool { finished.wait(timeout: .now() + seconds) == .success }
}
