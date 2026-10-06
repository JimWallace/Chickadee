// APIServer/MCP/Tools/MCPContentByteCap.swift
//
// The byte cap and the capped UTF-8 reader that the two MCP file-read tools
// share (`get_support_files`, `get_assignment_version`). They had one copy each,
// and the copies disagreed: one backed off at most 3 bytes, the other dropped a
// byte at a time over the whole prefix, so it was quadratic and could return
// the ASCII start of a binary file as text (#2334).

import Core
import Foundation

enum MCPContentByteCap {
    static let defaultBytes = 65_536
    static let maxBytes = 512_000

    /// The `maxBytes` input property, with its default and range taken from
    /// the constants above.
    static let schema: JSONValue = .object([
        "type": .string("integer"),
        "description": .string(
            "Read mode: max content bytes returned (default \(defaultBytes), clamped 1-\(maxBytes))."),
    ])

    /// The cap for a requested `maxBytes`: the default when absent, else the
    /// request clamped to 1...maxBytes.
    static func resolve(_ requested: Int?) -> Int {
        min(max(requested ?? defaultBytes, 1), maxBytes)
    }

    /// Up to `cap` bytes of `data` as UTF-8, backing off to a character
    /// boundary when the cap splits a multi-byte sequence. Nil when the content
    /// is not UTF-8 text: a UTF-8 character is at most 4 bytes, so if 3 bytes
    /// of back-off do not give valid text, the fault is not at the cut.
    static func cappedUTF8(_ data: Data, cap: Int) -> (content: String, truncated: Bool)? {
        guard data.count > cap else {
            return String(data: data, encoding: .utf8).map { ($0, false) }
        }
        var head = data.prefix(cap)
        for _ in 0..<4 {
            if let text = String(data: head, encoding: .utf8) {
                return (text, true)
            }
            head = head.dropLast()
        }
        return nil
    }
}
