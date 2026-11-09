import Darwin
import Foundation

/// Paths named on the command lines of running processes.
/// A build that waits between compile steps holds no open files in its
/// `-derivedDataPath`, so open files alone cannot prove a build folder is idle.
enum ProcessArgumentPaths {
    /// Reads every process of the current user. Fails closed when this process's
    /// own arguments cannot be read, because then no other result can be trusted.
    static func capture() throws -> Set<String> {
        let ownArguments = arguments(of: getpid())
        guard ownArguments?.isEmpty == false else {
            throw FeatureFailure(message: "Running build commands could not be checked. Nothing was deleted.")
        }
        var result = Set<String>()
        for pid in processIdentifiers() where pid > 0 && pid != getpid() {
            guard let values = arguments(of: pid) else { continue }
            result.formUnion(paths(arguments: values, workingDirectory: workingDirectory(of: pid)))
        }
        return result
    }

    /// Absolute paths, `NAME=/path` values and, with a known working directory,
    /// relative operands. Flags are skipped. Results use cleanup path spelling.
    static func paths(arguments: [String], workingDirectory: String?) -> [String] {
        arguments.dropFirst().compactMap { argument -> String? in
            var value = argument
            if !value.hasPrefix("/"), let equals = value.firstIndex(of: "=") {
                let tail = String(value[value.index(after: equals)...])
                guard tail.hasPrefix("/") else { return nil }
                value = tail
            }
            if value.isEmpty || value.hasPrefix("-") || value.contains("\n") { return nil }
            if !value.hasPrefix("/") {
                guard let workingDirectory, workingDirectory.hasPrefix("/") else { return nil }
                value = workingDirectory + "/" + value
            }
            let path = CleanupPath.fileURL(URL(fileURLWithPath: value)).path
            return path == "/" ? nil : path
        }
    }

    private static func processIdentifiers() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var values = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = values.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        }
        return count > 0 ? Array(values.prefix(Int(count))) : []
    }

    /// Parses KERN_PROCARGS2: argc, the executable path, padding, then argv.
    static func arguments(of pid: pid_t) -> [String]? {
        var maximum: Int32 = 0, size = MemoryLayout<Int32>.size
        var query = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&query, 2, &maximum, &size, nil, 0) == 0, maximum > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(maximum))
        var length = buffer.count
        query = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&query, 3, &buffer, &length, nil, 0) == 0, length > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < length && buffer[index] != 0 { index += 1 }
        while index < length && buffer[index] == 0 { index += 1 }
        var values: [String] = []
        while values.count < Int(argc) && index < length {
            let start = index
            while index < length && buffer[index] != 0 { index += 1 }
            values.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return values
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }
}
