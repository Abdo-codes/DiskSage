import Darwin
import Foundation

/// A same-user Unix socket. It carries commands to the GUI, never filesystem paths.
enum LocalToolConnection {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/DiskSage")
    }
    static var socketPath: String { directory.appending(path: "control.sock").path }
    static let maximumFrameSize = 65_536

    enum ConnectionError: Error, LocalizedError {
        case unavailable, unsafeEndpoint, invalidFrame
        var errorDescription: String? {
            switch self {
            case .unavailable: "DiskSage is unavailable. Open the DiskSage app and retry."
            case .unsafeEndpoint: "DiskSage could not secure its local agent connection."
            case .invalidFrame: "Invalid or oversized DiskSage tool message."
            }
        }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ConnectionError.unsafeEndpoint }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func configure(_ fd: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func sameUser(_ fd: Int32) -> Bool {
        var uid = uid_t.max
        var gid = gid_t.max
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }

    static func readFrame(_ fd: Int32) throws -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < maximumFrameSize {
            let count = Darwin.read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { throw ConnectionError.invalidFrame }
            if byte == 0x0A { return data }
            data.append(byte)
        }
        throw ConnectionError.invalidFrame
    }

    static func writeFrame(_ data: Data, to fd: Int32) throws {
        guard data.count < maximumFrameSize else { throw ConnectionError.invalidFrame }
        var framed = data
        framed.append(0x0A)
        try framed.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: sent), buffer.count - sent)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ConnectionError.unavailable }
                sent += count
            }
        }
    }

    static func call(_ request: AgentToolRequest, path: String = socketPath) throws -> AgentToolReply {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConnectionError.unavailable }
        defer { close(fd) }
        configure(fd)
        var endpoint = try address(path)
        let connected = withUnsafePointer(to: &endpoint) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ConnectionError.unavailable }
        guard sameUser(fd) else { throw ConnectionError.unsafeEndpoint }
        try writeFrame(JSONEncoder().encode(request), to: fd)
        return try JSONDecoder().decode(AgentToolReply.self, from: readFrame(fd))
    }
}
