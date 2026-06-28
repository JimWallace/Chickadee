// APIServer/MCP/Admin/Tools/GetDeployHistoryTool.swift
//
// Read tool: return the most recent entries from the auto-deploy daemon's
// append-only history log (history.jsonl in the deploy state dir, mounted
// read-only). Each entry records a deploy/gate/rollback event with its result —
// the operational record of what the CD loop has done.
//
// Read-only and side-effect-free: it reads a small log file the daemon owns.

import Core
import Foundation
import Vapor

struct GetDeployHistoryTool: DiagnosticTool {
    struct Input: Decodable, Sendable {
        /// Max entries to return, newest first. Defaults to 20, clamped to 1...100.
        let limit: Int?
    }

    struct Entry: Encodable, Sendable {
        let ts: String?
        let version: String?
        let action: String?
        let result: String?
        let detail: String?
    }

    struct Output: Encodable, Sendable {
        /// false when the history file is missing/unreadable.
        let available: Bool
        /// Most-recent-first deploy events.
        let entries: [Entry]
        /// Explanation when `available` is false.
        let note: String?
    }

    private struct EntryFile: Decodable {
        let ts: String?
        let version: String?
        let action: String?
        let result: String?
        let detail: String?
    }

    static let name = "get_deploy_history"
    static let description =
        "Return the most recent entries from the auto-deploy daemon's append-only history log: "
        + "each deploy / gate-hold / rollback event with its version, action, result, and detail, "
        + "newest first. Accepts an optional `limit` (default 20, max 100). Returns "
        + "available=false if the daemon is not running or its state dir is not mounted. "
        + "Read-only; reads a small log file the daemon owns and touches no course, student, or "
        + "database state."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Max entries to return, newest first (default 20, max 100)."),
                "minimum": .int(1),
                "maximum": .int(100),
            ])
        ]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        try await context.requireAdminSubject(tool: Self.name)

        let limit = min(max(input.limit ?? 20, 1), 100)
        let path = URL(fileURLWithPath: context.request.application.deployStateDirectory)
            .appendingPathComponent("history.jsonl")

        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            return Output(
                available: false, entries: [],
                note: "No deploy history at \(path.path) — the auto-deploy daemon may not be "
                    + "running, or its state directory is not mounted into this container.")
        }

        let decoder = JSONDecoder()
        // One JSON object per line; newest entries are appended last, so take the
        // tail and reverse to return newest-first.
        let parsed: [Entry] =
            text
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Entry? in
                guard let e = try? decoder.decode(EntryFile.self, from: Data(line.utf8))
                else { return nil }
                return Entry(
                    ts: e.ts, version: e.version, action: e.action, result: e.result,
                    detail: e.detail)
            }
        let newestFirst = Array(parsed.suffix(limit).reversed())
        return Output(available: true, entries: newestFirst, note: nil)
    }
}
