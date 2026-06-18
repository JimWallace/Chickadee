// APIServer/MCP/Admin/Tools/GetBrightSpaceSyncStatusTool.swift
//
// Read tool: BrightSpace grade-sync health — counts by status (success / error
// / skipped) over a window plus recent ERROR samples carrying the D2L API error
// detail, so an agent can tell whether grade pushes are failing and why.
//
// PII boundary (code allowlist): brightspace_sync_log is the most PII-laden
// diagnostic source — it stores a student `username` + the pushed `points`
// (a grade) per row. The returned DTO is hand-built and DELIBERATELY OMITS
// username, points, and user_id. It keeps only the status, the D2L error
// detail (infrastructure text), the test-setup id + assignment title
// (instructor content), the org-unit id, and the timestamp. Asserted by a
// per-tool PII test.

import Core
import Fluent
import Vapor

struct GetBrightSpaceSyncStatusTool: DiagnosticTool {
    struct Input: Decodable, Sendable {
        /// Look-back window in hours (default 168 = 7 days; clamped 1…720).
        var windowHours: Int?
        /// Max recent error samples to return (default 20; clamped 1…100).
        var sampleLimit: Int?
    }

    struct CountEntry: Encodable, Sendable {
        let key: String
        let count: Int
    }

    /// A failed grade-push, redacted: no username, points, or user_id.
    struct ErrorSample: Encodable, Sendable {
        let detail: String?
        let testSetupID: String
        let assignmentTitle: String
        let orgUnitID: String?
        let attemptedAt: Date
    }

    struct Output: Encodable, Sendable {
        let windowHours: Int
        let total: Int
        let byStatus: [CountEntry]
        let recentErrors: [ErrorSample]
    }

    static let name = "get_brightspace_sync_status"
    static let description =
        "BrightSpace grade-sync health: totals and counts by status (success / error / skipped) over "
        + "a window, plus recent ERROR samples carrying the D2L API error detail. Use it to tell "
        + "whether grade pushes are failing and why. Optional windowHours (default 168, max 720) and "
        + "sampleLimit. Read-only; the per-row student username and pushed grade (points) are "
        + "deliberately omitted — only status, error detail, assignment/test-setup, org unit, and "
        + "timestamp are returned."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "windowHours": .object([
                "type": .string("integer"),
                "description": .string("Look-back window in hours (default 168, max 720)."),
            ]),
            "sampleLimit": .object([
                "type": .string("integer"),
                "description": .string("Max recent error samples (default 20, max 100)."),
            ]),
        ]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        try await context.requireAdminSubject(tool: Self.name)

        let windowHours = min(max(input.windowHours ?? 168, 1), 720)
        let sampleLimit = min(max(input.sampleLimit ?? 20, 1), 100)
        let since = Date().addingTimeInterval(Double(-windowHours) * 3600)

        let rows = try await APIBrightSpaceSyncLog.query(on: context.db)
            .filter(\.$attemptedAt >= since)
            .sort(\.$attemptedAt, .descending)
            .all()

        var byStatus: [String: Int] = [:]
        for row in rows {
            byStatus[row.status, default: 0] += 1
        }

        let recentErrors =
            rows
            .filter { $0.status == APIBrightSpaceSyncLog.Status.error.rawValue }
            .prefix(sampleLimit)
            .map { row in
                ErrorSample(
                    detail: row.detail,
                    testSetupID: row.testSetupID,
                    assignmentTitle: row.assignmentTitle,
                    orgUnitID: row.orgUnitID,
                    attemptedAt: row.attemptedAt ?? Date())
            }

        return Output(
            windowHours: windowHours,
            total: rows.count,
            byStatus: byStatus.map { CountEntry(key: $0.key, count: $0.value) }
                .sorted { ($0.count, $1.key) > ($1.count, $0.key) },
            recentErrors: Array(recentErrors))
    }
}
