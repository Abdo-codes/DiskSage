import Darwin
import Foundation

final class AgentToolServer: @unchecked Sendable {
    private let ioQueue = DispatchQueue(label: "DiskSage.AgentToolServer.IO")
    private let listener: Int32
    private let lockFile: Int32
    private let path: String
    private let handler: @MainActor @Sendable (AgentToolRequest) -> AgentToolReply

    init(directory: URL = LocalToolConnection.directory,
         handler: @escaping @MainActor @Sendable (AgentToolRequest) -> AgentToolReply) throws {
        self.handler = handler
        path = directory.appending(path: "control.sock").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw LocalToolConnection.ConnectionError.unsafeEndpoint
        }
        let lock = open(directory.appending(path: "control.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw LocalToolConnection.ConnectionError.unsafeEndpoint }
        guard fstat(lock, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw LocalToolConnection.ConnectionError.unsafeEndpoint
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { close(lock); throw LocalToolConnection.ConnectionError.unavailable }
        do {
            if lstat(path, &info) == 0 {
                guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK else {
                    throw LocalToolConnection.ConnectionError.unsafeEndpoint
                }
                guard unlink(path) == 0 else { throw LocalToolConnection.ConnectionError.unsafeEndpoint }
            } else if errno != ENOENT {
                throw LocalToolConnection.ConnectionError.unsafeEndpoint
            }
            var address = try LocalToolConnection.address(path)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
                throw LocalToolConnection.ConnectionError.unavailable
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        } catch {
            close(fd)
            close(lock)
            throw error
        }
        listener = fd
        lockFile = lock
    }

    deinit {
        close(listener)
        unlink(path)
        close(lockFile)
    }

    private struct Incoming: Sendable {
        let descriptor: Int32
        let request: AgentToolRequest
    }

    /// Blocking socket operations never occupy Swift's cooperative or main executor.
    func serve() async {
        while !Task.isCancelled {
            guard let incoming = await readNext() else { continue }
            let reply = Task.isCancelled ? AgentToolReply(error: "DiskSage is shutting down.") : await handler(incoming.request)
            await withCheckedContinuation { continuation in
                ioQueue.async {
                    if let data = try? JSONEncoder().encode(reply) {
                        try? LocalToolConnection.writeFrame(data, to: incoming.descriptor)
                    }
                    close(incoming.descriptor)
                    continuation.resume()
                }
            }
        }
    }

    private func readNext() async -> Incoming? {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                var pollDescriptor = pollfd(fd: self.listener, events: Int16(POLLIN), revents: 0)
                guard poll(&pollDescriptor, 1, 250) > 0 else { continuation.resume(returning: nil); return }
                let client = accept(self.listener, nil, nil)
                guard client >= 0 else { continuation.resume(returning: nil); return }
                LocalToolConnection.configure(client)
                if LocalToolConnection.sameUser(client),
                   let data = try? LocalToolConnection.readFrame(client),
                   let request = try? JSONDecoder().decode(AgentToolRequest.self, from: data) {
                    continuation.resume(returning: Incoming(descriptor: client, request: request))
                } else {
                    let reply = AgentToolReply(error: "Invalid local tool request.")
                    if let data = try? JSONEncoder().encode(reply) { try? LocalToolConnection.writeFrame(data, to: client) }
                    close(client)
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
