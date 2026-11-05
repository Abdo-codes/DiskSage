import Foundation

enum ToolPage {
    static func make(_ values: [ToolValue], key: String, offset: Int, limit: Int) throws -> ToolValue {
        var items: [ToolValue] = [], size = 0
        for value in values.dropFirst(min(offset, values.count)).prefix(limit) {
            let bytes = try JSONEncoder().encode(value).count
            guard bytes < 24_000 else { throw FeatureFailure(message: "One result exceeds the tool response limit. Use a more specific query or inspect it in DiskSage.") }
            if size + bytes > 24_000 { break }
            items.append(value); size += bytes
        }
        let next = min(offset, values.count) + items.count
        return .object([key: .array(items), "total_count": .integer(values.count), "offset": .integer(offset),
            "next_offset": next < values.count ? .integer(next) : .null])
    }
}
