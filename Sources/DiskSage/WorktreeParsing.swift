import Foundation

enum WorktreeParsing {
    static func records(_ data: Data, common: String) throws -> [GitWorktree] {
        guard let string = String(data: data, encoding: .utf8) else { throw FeatureFailure(message: "Non-UTF8 Git paths are unsupported.") }
        var rows: [GitWorktree] = [], fields: [String: String] = [:]
        func finish() {
            guard let path = fields["worktree"] else { fields = [:]; return }
            rows.append(GitWorktree(path: path, commonDirectory: common, branch: fields["branch"], head: fields["HEAD"] ?? "",
                locked: fields["locked"] != nil, missing: fields["prunable"] != nil,
                main: rows.isEmpty))
            fields = [:]
        }
        for token in string.components(separatedBy: "\0") {
            if token.isEmpty { finish(); continue }
            let parts = token.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            fields[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
        }
        finish()
        return rows
    }
    static func status(_ data: Data, into value: inout WorktreeInspection) throws {
        guard let string = String(data: data, encoding: .utf8) else { throw FeatureFailure(message: "Non-UTF8 file names are unsupported.") }
        let records = string.components(separatedBy: "\0")
        var index = 0
        while index < records.count {
            let record = records[index]; index += 1
            if record.isEmpty { continue }
            switch record.first {
            case "?": value.untracked.append(String(record.dropFirst(2)))
            case "!": value.ignored.append(String(record.dropFirst(2)))
            case "1", "2", "u":
                let count = record.first == "1" ? 8 : (record.first == "2" ? 9 : 10)
                let parts = record.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false)
                guard parts.count == count + 1, parts[1].count == 2 else { throw FeatureFailure(message: "Incomplete Git status.") }
                let path = String(parts[count]), xy = Array(parts[1])
                if record.first == "u" { value.conflicted.append(path) }
                if xy[0] != "." { value.staged.append(path) }
                if xy[1] != "." { value.modified.append(path) }
                if parts[2].first == "S" { value.blockers.append("Submodule state is unsupported.") }
                if record.first == "2" { guard index < records.count else { throw FeatureFailure(message: "Incomplete rename status.") }; index += 1 }
            default: throw FeatureFailure(message: "Unrecognized Git status record.")
            }
        }
    }
}
