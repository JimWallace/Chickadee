// APIServer/MCP/Protocol/MCPListPagination.swift
//
// Cursor-based pagination for the MCP list operations (`tools/list`,
// `resources/list`).  Cursors are opaque to clients per the spec; here they
// encode a plain offset, which is stable because both lists have a
// deterministic order (name-sorted tools, title-sorted resources).
// https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/pagination

import Core
import Foundation

enum MCPListPagination {
    /// Entries per page.  Generous: the 34-tool catalog fits one page, so only
    /// genuinely large listings (resources on a big deployment) paginate.
    static let defaultPageSize = 100

    /// The opaque cursor naming the page that starts at `offset`.
    static func cursor(forOffset offset: Int) -> String {
        Data("offset:\(offset)".utf8).base64EncodedString()
    }

    /// Decodes a cursor minted by `cursor(forOffset:)`; nil for anything else.
    static func offset(fromCursor cursor: String) -> Int? {
        guard let data = Data(base64Encoded: cursor),
            let text = String(data: data, encoding: .utf8),
            text.hasPrefix("offset:"),
            let value = Int(text.dropFirst("offset:".count)),
            value >= 0
        else { return nil }
        return value
    }

    /// Slices `entries` into the page named by `cursor` (nil = first page) and
    /// the `nextCursor` to advertise (nil on the last page).  Returns nil when
    /// the cursor is unparseable — the caller reports invalidParams.  A
    /// well-formed cursor past the end of the list (e.g. the list shrank
    /// between pages) yields an empty final page rather than an error.
    static func page(
        _ entries: [JSONValue], cursor: String?, pageSize: Int = defaultPageSize
    ) -> (page: [JSONValue], nextCursor: String?)? {
        let start: Int
        if let cursor {
            guard let offset = offset(fromCursor: cursor) else { return nil }
            start = offset
        } else {
            start = 0
        }
        guard start < entries.count else { return ([], nil) }
        let end = min(start + pageSize, entries.count)
        let next = end < entries.count ? self.cursor(forOffset: end) : nil
        return (Array(entries[start..<end]), next)
    }
}
