// APIServer/MCP/Admin/Tools/GetBrowserDiagnosticsTool.swift
//
// Read tool: surface the in-browser editor's error reports (client_diagnostics)
// for diagnosis — counts by kind/source/failed-check over a window, plus recent
// redacted samples carrying the actual error message + stack captured in the
// browser-error enrichment work.
//
// PII boundary (code allowlist — the shipped guarantee, no DB role): the
// returned DTO is hand-built and deliberately OMITS user_id. It keeps the
// failure kind, source, failed checks, error message/stack (JupyterLite/Pyodide
// infrastructure text only — capture is restricted to the editor-load path,
// never student-code execution), the user agent, the test-setup id (instructor
// content, not student data), and the timestamp. No student identifier is ever
// included.

import Core
import Fluent
import Vapor

struct GetBrowserDiagnosticsTool: DiagnosticTool {
    struct Input: Decodable, Sendable {
        /// Look-back window in hours (default 168 = 7 days; clamped 1…720).
        var windowHours: Int?
        /// Optional test-setup (assignment) filter.
        var testSetupID: String?
        /// Max recent samples to return (default 20; clamped 1…100).
        var sampleLimit: Int?
    }

    struct CountEntry: Encodable, Sendable {
        let key: String
        let count: Int
    }

    /// A single browser-error report, redacted: no user_id.
    struct Sample: Encodable, Sendable {
        let kind: String
        let source: String?
        let failedChecks: String?
        let message: String?
        let stack: String?
        let userAgent: String?
        let testSetupID: String?
        let createdAt: Date
    }

    struct Output: Encodable, Sendable {
        let windowHours: Int
        let total: Int
        let byKind: [CountEntry]
        let bySource: [CountEntry]
        let byFailedCheck: [CountEntry]
        /// Submit-flow funnel: `submit_phase` breadcrumb counts in phase order
        /// (grading_start → … → result_posted). The drop-off between consecutive
        /// phases shows where in-browser submissions are lost to a freeze — the
        /// last phase a frozen student reaches has no successor record.
        let submitFunnel: [CountEntry]
        let recentSamples: [Sample]
    }

    /// Canonical order of the browser submit/grading breadcrumbs (emitted by
    /// `recordSubmitPhase` in Public/browser-runner.js).
    static let submitPhaseOrder = [
        "grading_start", "runtime_loaded", "setup_unpacked",
        "suite_started", "suite_done", "result_posting", "result_posted",
    ]

    static let name = "get_browser_diagnostics"
    static let description =
        "In-browser editor + submission diagnostics (JupyterLite/Pyodide) for diagnosis: totals and "
        + "breakdowns by kind (preflight_fail / watchdog_timeout / editor_error for editor load, and "
        + "submit_phase / submit_error for the grading/submission flow), source, and failed capability "
        + "check over a window, plus recent samples carrying the actual error message and stack. Also "
        + "returns submitFunnel: the submit_phase breadcrumb counts in phase order "
        + "(grading_start → runtime_loaded → setup_unpacked → suite_started → suite_done → "
        + "result_posting → result_posted) — the drop-off between consecutive phases shows where "
        + "in-browser submissions are lost to a freeze (a frozen student's last reached phase has no "
        + "successor). Optionally filter by testSetupID. Read-only; reports infrastructure breadcrumbs "
        + "only and never includes a student identifier."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "windowHours": .object([
                "type": .string("integer"),
                "description": .string("Look-back window in hours (default 168, max 720)."),
            ]),
            "testSetupID": .object([
                "type": .string("string"),
                "description": .string("Optional assignment/test-setup id filter."),
            ]),
            "sampleLimit": .object([
                "type": .string("integer"),
                "description": .string("Max recent samples to return (default 20, max 100)."),
            ]),
        ]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        try await context.requireAdminSubject(tool: Self.name)

        let windowHours = min(max(input.windowHours ?? 168, 1), 720)
        let sampleLimit = min(max(input.sampleLimit ?? 20, 1), 100)
        let since = Date().addingTimeInterval(Double(-windowHours) * 3600)

        var query = APIClientDiagnostic.query(on: context.db)
            .filter(\.$createdAt >= since)
        if let setup = input.testSetupID, !setup.isEmpty {
            query = query.filter(\.$testSetupID == setup)
        }
        let rows = try await query.sort(\.$createdAt, .descending).all()

        var byKind: [String: Int] = [:]
        var bySource: [String: Int] = [:]
        var byCheck: [String: Int] = [:]
        for row in rows {
            byKind[row.kind, default: 0] += 1
            if let source = row.source { bySource[source, default: 0] += 1 }
            if let checks = row.failedChecks {
                for check in checks.split(separator: ",") {
                    byCheck[String(check), default: 0] += 1
                }
            }
        }

        // Submit-flow funnel from the `submit_phase` breadcrumbs, in phase order
        // (then any unknown phases by count). The drop-off pinpoints the freeze.
        let submitPhaseCounts = rows.reduce(into: [String: Int]()) { acc, row in
            if row.kind == "submit_phase", let source = row.source { acc[source, default: 0] += 1 }
        }
        var submitFunnel = Self.submitPhaseOrder.compactMap { phase -> CountEntry? in
            submitPhaseCounts[phase].map { CountEntry(key: phase, count: $0) }
        }
        let knownPhases = Set(Self.submitPhaseOrder)
        submitFunnel += Self.sortedCounts(submitPhaseCounts.filter { !knownPhases.contains($0.key) })

        let samples = rows.prefix(sampleLimit).map { row in
            Sample(
                kind: row.kind,
                source: row.source,
                failedChecks: row.failedChecks,
                message: row.message,
                stack: row.stack,
                userAgent: row.userAgent,
                testSetupID: row.testSetupID,
                createdAt: row.createdAt ?? Date())
        }

        return Output(
            windowHours: windowHours,
            total: rows.count,
            byKind: Self.sortedCounts(byKind),
            bySource: Self.sortedCounts(bySource),
            byFailedCheck: Self.sortedCounts(byCheck),
            submitFunnel: submitFunnel,
            recentSamples: Array(samples))
    }

    /// Counts as entries, highest first then by key for stable ordering.
    private static func sortedCounts(_ counts: [String: Int]) -> [CountEntry] {
        counts.map { CountEntry(key: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.key) > ($1.count, $0.key) }
    }
}
