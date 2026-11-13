import Foundation

enum WorktreeActivity {
    /// A Mac with many open files gives more than 8 MB of lsof output. A cut list would hide an active process.
    static let lsofOutputLimit = 256_000_000

    /// The working directories and executables of all processes.
    static func capture(_ git: WorktreeGitProcess) throws -> [String] {
        let output = try git.execute("/usr/sbin/lsof", ["-nP", "-d", "cwd,txt", "-F0pn"], outputLimit: lsofOutputLimit)
        guard output.code == 0 else { throw FeatureFailure(message: "Process activity could not be checked.") }
        return try paths(output.data)
    }

    /// lsof escapes control characters and, under the C locale, each non-ASCII byte.
    static func paths(_ output: Data) throws -> [String] {
        try output.split(separator: 0).filter { $0.starts(with: [110, 47]) }.map { field in
            let input = Array(field.dropFirst())
            let escapes: [UInt8: UInt8] = [110: 10, 116: 9, 114: 13, 98: 8, 102: 12, 118: 11, 97: 7, 101: 27, 92: 92]
            var decoded: [UInt8] = [], index = 0
            func invalid() -> FeatureFailure { FeatureFailure(message: "Unrecognized escaping in process activity paths; activity cannot be established.") }
            while index < input.count {
                let byte = input[index]; index += 1
                if byte != 92 { decoded.append(byte); continue }
                guard index < input.count else { throw invalid() }
                if let value = escapes[input[index]] { decoded.append(value); index += 1 }
                else if input[index] == 120 {
                    guard index + 2 < input.count,
                          let value = UInt8(String(decoding: input[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) else { throw invalid() }
                    decoded.append(value); index += 3
                } else if (48...55).contains(input[index]) {
                    guard index + 2 < input.count,
                          let value = UInt8(String(decoding: input[index...(index + 2)], as: UTF8.self), radix: 8) else { throw invalid() }
                    decoded.append(value); index += 3
                } else { throw invalid() }
            }
            guard let path = String(bytes: decoded, encoding: .utf8) else { throw invalid() }
            return path
        }
    }
}
