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
        /// Events grouped by coarse browser/OS (e.g. "Safari/iOS", "Chrome/Windows")
        /// so failures vs successes can be seen per browser/device class — the
        /// breakdown needed to localize editor problems (e.g. "Kernel Unknown" on
        /// a specific platform). Derived from the User-Agent; no student identity.
        let byBrowser: [CountEntry]
        /// Submit-flow funnel: `submit_phase` breadcrumb counts in phase order
        /// (grading_start → … → result_posted). The drop-off between consecutive
        /// phases shows where in-browser submissions are lost to a freeze — the
        /// last phase a frozen student reaches has no successor record.
        let submitFunnel: [CountEntry]
        /// Kernel-boot funnel: `kernel_phase` breadcrumb counts in phase order
        /// (boot_start → app_ready → kernel_starting → kernel_idle), forwarded by
        /// the in-iframe collector. The drop-off localizes WHERE a kernel boot
        /// stalls — a kernel that spins forever reaches some phase and stops, so
        /// `kernel_idle` far below `boot_start` is the hung-kernel signature the
        /// parent page could never see across the iframe boundary. Pair with the
        /// `kernel_error` rows in bySource/recentSamples for the WHY.
        let kernelBootFunnel: [CountEntry]
        let recentSamples: [Sample]
    }

    /// Canonical order of the browser submit/grading breadcrumbs (emitted by
    /// `recordSubmitPhase` in Public/browser-runner.js).
    static let submitPhaseOrder = [
        "grading_start", "runtime_loaded", "setup_unpacked",
        "suite_started", "suite_done", "result_posting", "result_posted",
    ]

    /// Canonical order of the kernel-boot breadcrumbs (emitted by the in-iframe
    /// collector Public/jl-kernel-diagnostics.js, forwarded by notebook.js).
    static let kernelPhaseOrder = [
        "boot_start", "app_ready", "kernel_starting", "kernel_idle",
    ]

    static let name = "get_browser_diagnostics"
    static let description =
        "In-browser editor + submission diagnostics (JupyterLite/Pyodide) for diagnosis: totals and "
        + "breakdowns by kind (preflight_fail / watchdog_timeout / editor_error / page_unresponsive for "
        + "editor-load failures, editor_ready as the success denominator and sw_state for service-worker "
        + "registration, and submit_phase / submit_error for the grading/submission flow), by source, by "
        + "failed capability check, and by browser/OS (byBrowser, e.g. Safari/iOS) so failures can be "
        + "localized per device class, over a window, plus recent samples with the error message and stack. Also "
        + "returns submitFunnel: the submit_phase breadcrumb counts in phase order "
        + "(grading_start → runtime_loaded → setup_unpacked → suite_started → suite_done → "
        + "result_posting → result_posted) — the drop-off between consecutive phases shows where "
        + "in-browser submissions are lost to a freeze (a frozen student's last reached phase has no "
        + "successor). And kernelBootFunnel: the kernel_phase breadcrumb counts in phase order "
        + "(boot_start → app_ready → kernel_starting → kernel_idle), forwarded by the in-iframe "
        + "collector — the drop-off localizes WHERE a kernel boot stalls (a kernel that spins forever "
        + "reaches some phase and stops, so kernel_idle far below boot_start is the hung-kernel "
        + "signature); pair it with the kernel_error rows (in bySource / recentSamples: csp_violation, "
        + "resource_error, kernel_dead, boot_stalled, exec_hang, …) for the WHY. exec_hang is the "
        + "POST-IDLE hang the boot funnel can't see: the kernel booted to idle (counted as success) "
        + "then wedged on execute, so cells sit busy forever; its count is distinct students who hit a "
        + "sustained-busy hang, message busy_ms=… the hang duration. Optionally filter by testSetupID. "
        + "Read-only; reports infrastructure breadcrumbs only and never includes a student identifier."
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
        var byBrowser: [String: Int] = [:]
        for row in rows {
            byKind[row.kind, default: 0] += 1
            byBrowser[Self.browserLabel(forUserAgent: row.userAgent), default: 0] += 1
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

        // Kernel-boot funnel from the `kernel_phase` breadcrumbs, in phase order
        // (then any unknown phases by count). The drop-off pinpoints where a boot
        // stalls — the in-iframe collector's view of the cross-process kernel.
        let kernelPhaseCounts = rows.reduce(into: [String: Int]()) { acc, row in
            if row.kind == "kernel_phase", let source = row.source { acc[source, default: 0] += 1 }
        }
        var kernelBootFunnel = Self.kernelPhaseOrder.compactMap { phase -> CountEntry? in
            kernelPhaseCounts[phase].map { CountEntry(key: phase, count: $0) }
        }
        let knownKernelPhases = Set(Self.kernelPhaseOrder)
        kernelBootFunnel += Self.sortedCounts(kernelPhaseCounts.filter { !knownKernelPhases.contains($0.key) })

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
            byBrowser: Self.sortedCounts(byBrowser),
            submitFunnel: submitFunnel,
            kernelBootFunnel: kernelBootFunnel,
            recentSamples: Array(samples))
    }

    /// Counts as entries, highest first then by key for stable ordering.
    private static func sortedCounts(_ counts: [String: Int]) -> [CountEntry] {
        counts.map { CountEntry(key: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.key) > ($1.count, $0.key) }
    }

    /// Coarse, PII-safe "browser/OS" label from a User-Agent (e.g.
    /// "Chrome/Windows", "Safari/iOS"). Browser order matters — Chrome and
    /// Edge UAs also contain "Safari", and Edge contains "Chrome" — so the more
    /// specific tokens are checked first. "Unknown" when the UA is absent.
    static func browserLabel(forUserAgent userAgent: String?) -> String {
        guard let ua = userAgent, !ua.isEmpty else { return "Unknown" }

        let browser: String
        if ua.contains("Edg/") || ua.contains("Edge/") || ua.contains("EdgiOS/") {
            browser = "Edge"
        } else if ua.contains("Firefox/") || ua.contains("FxiOS/") {
            browser = "Firefox"
        } else if ua.contains("CriOS/") || ua.contains("Chrome/") || ua.contains("Chromium/") {
            browser = "Chrome"
        } else if ua.contains("Safari/") {
            browser = "Safari"
        } else {
            browser = "Other"
        }

        let os: String
        if ua.contains("Windows") {
            os = "Windows"
        } else if ua.contains("iPhone") || ua.contains("iPad") || ua.contains("iPod") {
            os = "iOS"
        } else if ua.contains("Android") {
            os = "Android"
        } else if ua.contains("Mac OS X") || ua.contains("Macintosh") {
            os = "macOS"
        } else if ua.contains("Linux") {
            os = "Linux"
        } else {
            os = "Other"
        }

        return "\(browser)/\(os)"
    }
}
