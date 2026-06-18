// Tests for the Phase-3 admin diagnostic tools: get_metrics_snapshot and
// get_health_alerts.  Both wrap PII-free operational aggregates and enforce
// admin-only access via AdminToolContext.requireAdminSubject.

import Core
import Fluent
import Logging
import Testing
import Vapor
import XCTVapor

@testable import APIServer

@Suite(.serialized) final class AdminMCPToolsTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "admin-mcp-tools")
    }

    private func context(subject: String, scopes: Set<DiagnosticScope> = [.read]) -> AdminToolContext {
        AdminToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: subject,
            grantedScopes: scopes)
    }

    @Test func getMetricsSnapshotReturnsAggregateForAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "ops-admin", role: "admin")
            let output = try await GetMetricsSnapshotTool().execute(
                .init(), context(subject: "ops-admin"))
            // Empty test deployment: no runners, no jobs — but the aggregate
            // still resolves with sane defaults.
            #expect(output.recentWindowHours >= 1)
            #expect(output.activeRunners == 0)
            #expect(output.runnerLoads.isEmpty)
        }
    }

    @Test func getMetricsSnapshotRejectsNonAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "ms-prof", role: "instructor")
            await #expect(throws: MCPToolError.self) {
                _ = try await GetMetricsSnapshotTool().execute(.init(), context(subject: "ms-prof"))
            }
        }
    }

    @Test func getHealthAlertsReturnsAllRulesForAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "ha-admin", role: "admin")
            let output = try await GetHealthAlertsTool().execute(
                .init(), context(subject: "ha-admin"))
            #expect(output.rules.count == HealthRule.allCases.count)
            // DB is reachable and there are no runners/jobs, so nothing fires.
            #expect(output.anyFiring == false)
            #expect(output.rules.allSatisfy { !$0.summary.isEmpty })
        }
    }

    @Test func getHealthAlertsRejectsNonAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "ha-student", role: "student")
            await #expect(throws: MCPToolError.self) {
                _ = try await GetHealthAlertsTool().execute(.init(), context(subject: "ha-student"))
            }
        }
    }

    @Test func getBrowserDiagnosticsAggregatesAndRedactsUserID() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "bd-admin", role: "admin")
            let student = try await makeTestUser(on: app, username: "bd-student", role: "student")
            let studentID = try student.requireID()
            let seeds: [(String, String?)] = [
                ("editor_error", "onerror"),
                ("editor_error", "unhandledrejection"),
                ("watchdog_timeout", "kernel"),
            ]
            for (kind, source) in seeds {
                try await APIClientDiagnostic(
                    userID: studentID, testSetupID: nil, kind: kind,
                    failedChecks: kind == "watchdog_timeout" ? "kernel-unhealthy" : nil,
                    userAgent: "TestUA/9", message: "TypeError: boom", stack: "at x (a.js:1:1)",
                    source: source
                ).save(on: app.db)
            }

            let output = try await GetBrowserDiagnosticsTool().execute(
                .init(), context(subject: "bd-admin"))
            #expect(output.total == 3)
            #expect(output.byKind.contains { $0.key == "editor_error" && $0.count == 2 })
            #expect(output.bySource.contains { $0.key == "onerror" && $0.count == 1 })
            #expect(output.byFailedCheck.contains { $0.key == "kernel-unhealthy" && $0.count == 1 })
            let sample = try #require(output.recentSamples.first)
            #expect(sample.message == "TypeError: boom")
            #expect(sample.stack == "at x (a.js:1:1)")

            // PII guarantee: the student's user id must not appear anywhere in
            // the serialized tool output.
            let json = try #require(String(bytes: JSONEncoder().encode(output), encoding: .utf8))
            #expect(!json.contains(studentID.uuidString))
            #expect(!json.lowercased().contains("userid"))
        }
    }

    @Test func getBrowserDiagnosticsRejectsNonAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "bd-prof", role: "instructor")
            await #expect(throws: MCPToolError.self) {
                _ = try await GetBrowserDiagnosticsTool().execute(.init(), context(subject: "bd-prof"))
            }
        }
    }

    @Test func queryLogsFiltersForAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "ql-admin", role: "admin")
            let sink = AdminEventSink(capacity: 100)
            sink.record(
                CapturedEvent(
                    timestamp: Date(), level: "warning", label: "a", message: "disk low",
                    metadata: ["job_id": "j1"]))
            sink.record(
                CapturedEvent(
                    timestamp: Date(), level: "error", label: "b", message: "runner crashed",
                    metadata: [:]))
            app.adminEventSink = sink

            let all = try await QueryLogsTool().execute(.init(), context(subject: "ql-admin"))
            #expect(all.matched == 2)
            #expect(all.entries.first?.level == "error")  // most-recent first

            let errorsOnly = try await QueryLogsTool().execute(
                .init(minLevel: "error"), context(subject: "ql-admin"))
            #expect(errorsOnly.matched == 1)

            let bySubstring = try await QueryLogsTool().execute(
                .init(contains: "disk"), context(subject: "ql-admin"))
            #expect(bySubstring.matched == 1)
            #expect(bySubstring.entries.first?.message == "disk low")
        }
    }

    @Test func queryLogsRejectsNonAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "ql-prof", role: "instructor")
            await #expect(throws: MCPToolError.self) {
                _ = try await QueryLogsTool().execute(.init(), context(subject: "ql-prof"))
            }
        }
    }

    // MARK: - get_metrics_card_series

    @Test func getMetricsCardSeriesReturnsAllWindowsForAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "mcs-admin", role: "admin")
            let output = try await GetMetricsCardSeriesTool().execute(
                .init(), context(subject: "mcs-admin"))
            // One entry per selectable window (24h / 7d / 30d), each with a full
            // bucket grid — empty test deployment, but the grid still resolves.
            #expect(output.windows.count == MetricsCardWindow.allCases.count)
            let day = try #require(output.windows.first { $0.window == "24h" })
            #expect(day.bucketLabels.count == 24)
            #expect(day.maxQueueDepth.series.count == 24)
        }
    }

    @Test func getMetricsCardSeriesRejectsNonAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "mcs-prof", role: "instructor")
            await #expect(throws: MCPToolError.self) {
                _ = try await GetMetricsCardSeriesTool().execute(.init(), context(subject: "mcs-prof"))
            }
        }
    }

    // MARK: - get_active_users_series

    @Test func getActiveUsersSeriesDefaultsToDayWindowForAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "aus-admin", role: "admin")
            let output = try await GetActiveUsersSeriesTool().execute(
                .init(), context(subject: "aus-admin"))
            #expect(output.window == "24h")
            #expect(output.buckets.count == 24)

            let week = try await GetActiveUsersSeriesTool().execute(
                .init(window: "1w"), context(subject: "aus-admin"))
            #expect(week.window == "1w")
            #expect(week.buckets.count == 7)
        }
    }

    @Test func getActiveUsersSeriesRejectsUnknownWindow() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "aus-admin2", role: "admin")
            await #expect(throws: MCPToolError.self) {
                _ = try await GetActiveUsersSeriesTool().execute(
                    .init(window: "90d"), context(subject: "aus-admin2"))
            }
        }
    }

    @Test func getActiveUsersSeriesRejectsNonAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "aus-prof", role: "instructor")
            await #expect(throws: MCPToolError.self) {
                _ = try await GetActiveUsersSeriesTool().execute(.init(), context(subject: "aus-prof"))
            }
        }
    }

    // MARK: - get_instructor_card_series

    @Test func getInstructorCardSeriesScopesToCourseAndRedactsStudentID() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "ics-admin", role: "admin")
            let course = try await makeTestCourse(on: app, code: "MCP101")
            let courseID = try course.requireID()
            let setup = try await makeTestSetup(on: app, id: "ics_setup", courseID: courseID)
            let student = try await makeTestUser(on: app, username: "ics-student", role: "student")
            let studentID = try student.requireID()
            try await makeTestEnrollment(on: app, userID: studentID, courseID: courseID)
            _ = try await makeTestSubmission(
                on: app, id: "ics_sub", setupID: try setup.requireID(), userID: studentID)

            let output = try await GetInstructorCardSeriesTool().execute(
                .init(courseCode: "mcp101"), context(subject: "ics-admin"))  // case-insensitive
            let day = try #require(output.windows.first { $0.window == "24h" })
            #expect(day.submissions.headline == 1)
            #expect(day.activeStudents.headline == 1)
            #expect(day.activeAssignments.headline == 1)

            // PII guarantee: no student identifier in the serialized output.
            let json = try #require(String(bytes: JSONEncoder().encode(output), encoding: .utf8))
            #expect(!json.contains(studentID.uuidString))
            #expect(!json.lowercased().contains("userid"))
        }
    }

    @Test func getInstructorCardSeriesRejectsUnknownCourse() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "ics-admin2", role: "admin")
            await #expect(throws: MCPToolError.self) {
                _ = try await GetInstructorCardSeriesTool().execute(
                    .init(courseCode: "NO-SUCH-COURSE"), context(subject: "ics-admin2"))
            }
        }
    }

    @Test func getInstructorCardSeriesRejectsNonAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "ics-prof", role: "instructor")
            await #expect(throws: MCPToolError.self) {
                _ = try await GetInstructorCardSeriesTool().execute(
                    .init(courseCode: "MCP101"), context(subject: "ics-prof"))
            }
        }
    }
}

// Pure-logic tests for the log ring-buffer handler — no app.
@Suite struct RingBufferLogHandlerTests {
    @Test func capturesWarningPlusAndRedactsPII() throws {
        let sink = AdminEventSink(capacity: 10)
        let handler = RingBufferLogHandler(label: "test", sink: sink)
        handler.log(
            event: LogEvent(
                level: .warning, message: "boom",
                metadata: ["user_id": "u1", "job_id": "j1"],
                source: "s", file: "f", function: "fn", line: 1))
        let event = try #require(sink.snapshot().first)
        #expect(event.level == "warning")
        #expect(event.message == "boom")
        #expect(event.metadata["job_id"] == "j1")
        // PII key dropped at capture.
        #expect(event.metadata["user_id"] == nil)
    }

    @Test func dropsBelowWarning() {
        let sink = AdminEventSink(capacity: 10)
        let handler = RingBufferLogHandler(label: "test", sink: sink)
        handler.log(
            event: LogEvent(
                level: .info, message: "hi", metadata: nil,
                source: "s", file: "f", function: "fn", line: 1))
        #expect(sink.snapshot().isEmpty)
    }
}

// Pure-logic catalog check — no app, so kept out of the class suite (which would
// otherwise build and leak a Vapor app for a test that doesn't need one).
@Suite struct AdminMCPCatalogTests {
    @Test func toolsAreRegistered() {
        let names = Set(AdminMCPToolCatalog.live.all.map(\.name))
        #expect(
            names.isSuperset(of: [
                "get_deployment_info", "get_metrics_snapshot", "get_metrics_card_series",
                "get_active_users_series", "get_instructor_card_series", "get_health_alerts",
                "get_browser_diagnostics", "query_logs",
            ]))
    }
}
