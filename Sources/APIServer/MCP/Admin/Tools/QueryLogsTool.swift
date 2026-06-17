// APIServer/MCP/Admin/Tools/QueryLogsTool.swift
//
// Read tool: query recent server log events (warning+ by default) from the
// in-process AdminEventSink ring buffer.  The buffer is fed by
// RingBufferLogHandler with PII metadata already dropped at capture, so this
// tool exposes infrastructure diagnostics without student identifiers. Filter
// by minimum level, message substring, and look-back window.

import Core
import Logging
import Vapor

struct QueryLogsTool: DiagnosticTool {
    struct Input: Decodable, Sendable {
        /// Max entries to return, most-recent first (default 100, clamped 1…500).
        var limit: Int?
        /// Minimum level to include ("warning", "error", "critical", …).
        /// Defaults to everything in the buffer (which is already warning+).
        var minLevel: String?
        /// Case-insensitive substring the message must contain.
        var contains: String?
        /// Look-back window in minutes (default: the whole buffer).
        var sinceMinutes: Int?
    }

    struct Entry: Encodable, Sendable {
        let timestamp: Date
        let level: String
        let label: String
        let message: String
        let metadata: [String: String]
    }

    struct Output: Encodable, Sendable {
        /// Entries matching the filter, most-recent first (capped by `limit`).
        let entries: [Entry]
        /// How many matched before the `limit` cap.
        let matched: Int
        /// Ring-buffer capacity, so a caller can tell when history may be truncated.
        let bufferCapacity: Int
        /// Operational caveat surfaced to the agent.
        let note: String
    }

    static let name = "query_logs"
    static let description =
        "Recent server log events (warning and above) from an in-process ring buffer, for "
        + "diagnosis. Filter by minLevel, a message substring (contains), and sinceMinutes. "
        + "Returns most-recent-first entries with level, label, message, and PII-redacted "
        + "metadata. Read-only; the buffer is per-process and resets on restart, and student "
        + "identifiers are dropped at capture."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "limit": .object([
                "type": .string("integer"), "description": .string("Max entries (default 100, max 500)."),
            ]),
            "minLevel": .object([
                "type": .string("string"),
                "description": .string("Minimum level: warning | error | critical."),
            ]),
            "contains": .object([
                "type": .string("string"), "description": .string("Case-insensitive message substring."),
            ]),
            "sinceMinutes": .object([
                "type": .string("integer"), "description": .string("Look-back window in minutes."),
            ]),
        ]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        try await context.requireAdminSubject(tool: Self.name)

        let capacity = context.request.application.adminEventSink?.bufferCapacity ?? 0
        let all = context.request.application.adminEventSink?.snapshot() ?? []

        let limit = min(max(input.limit ?? 100, 1), 500)
        let minLevel = input.minLevel.flatMap { Logger.Level(rawValue: $0.lowercased()) }
        let needle = input.contains?.lowercased()
        let since = input.sinceMinutes.map { Date().addingTimeInterval(Double(-$0) * 60) }

        let matched =
            all
            .filter { event in
                if let since, event.timestamp < since { return false }
                if let minLevel, let level = Logger.Level(rawValue: event.level), level < minLevel {
                    return false
                }
                if let needle, !event.message.lowercased().contains(needle) { return false }
                return true
            }

        // Most-recent first, capped.
        let entries = matched.suffix(limit).reversed().map { event in
            Entry(
                timestamp: event.timestamp, level: event.level, label: event.label,
                message: event.message, metadata: event.metadata)
        }

        return Output(
            entries: Array(entries),
            matched: matched.count,
            bufferCapacity: capacity,
            note: "In-process ring buffer (warning+); per-process and reset on restart.")
    }
}
