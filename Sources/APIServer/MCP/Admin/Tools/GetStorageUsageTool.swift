// APIServer/MCP/Admin/Tools/GetStorageUsageTool.swift
//
// Read tool: on-disk footprint — total bytes by component (submissions /
// test-setups / results+logs / static assets / database) plus a per-assignment
// breakdown.  Wraps the same builder the admin /admin/storage page uses
// (`AdminRoutes.makeStorageContext`).  Disk pressure directly causes job
// failures (free disk is tracked per job), so this is a first-class diagnostic.
// PII-free: assignment title + course code are instructor content, submission
// COUNT per assignment is an aggregate — no student identifiers.

import Core
import Vapor

struct GetStorageUsageTool: DiagnosticTool {
    struct Input: Decodable, Sendable {}

    /// The existing admin storage panel context, reused verbatim — component
    /// totals + per-assignment byte/count breakdown, no student identifiers.
    typealias Output = AdminStorageContext

    static let name = "get_storage_usage"
    static let description =
        "On-disk footprint: total bytes by component (submissions / test-setups / results+logs / "
        + "static assets / database, with the database backend) plus a per-assignment breakdown "
        + "(test-suite bytes, submission bytes, submission count, sorted largest-first). Use it to "
        + "diagnose disk pressure (which causes job failures) and see which assignment is consuming "
        + "space. Read-only; assignment/course identifiers and byte/count aggregates only — no student "
        + "identifiers."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        try await context.requireAdminSubject(tool: Self.name)
        return try await AdminRoutes.makeStorageContext(req: context.request)
    }
}
