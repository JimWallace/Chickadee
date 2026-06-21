// Tests for the Phase-3 admin diagnostic tools: get_metrics_snapshot and
// get_health_alerts.  Both wrap PII-free operational aggregates and enforce
// admin-only access via AdminToolContext.requireAdminSubject.

import Core
import Fluent
import Logging
import Testing
import Vapor
import VaporTesting

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

    @Test func getBrowserDiagnosticsBuildsSubmitFunnelInPhaseOrder() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "bf-admin", role: "admin")
            let student = try await makeTestUser(on: app, username: "bf-student", role: "student")
            let studentID = try student.requireID()
            // submit_phase breadcrumbs reaching different depths, inserted out of
            // order with uneven counts — the funnel must come back in canonical
            // phase order so the drop-off (the freeze point) reads top-to-bottom.
            let phaseSeeds: [(String, Int)] = [
                ("result_posted", 2),
                ("grading_start", 5),
                ("suite_started", 4),
                ("runtime_loaded", 5),
                ("setup_unpacked", 4),
                ("suite_done", 3),
                ("result_posting", 2),
            ]
            for (phase, count) in phaseSeeds {
                for _ in 0..<count {
                    try await APIClientDiagnostic(
                        userID: studentID, testSetupID: nil, kind: "submit_phase",
                        failedChecks: nil, userAgent: "UA", message: "elapsed_ms=10",
                        stack: nil, source: phase
                    ).save(on: app.db)
                }
            }

            let output = try await GetBrowserDiagnosticsTool().execute(
                .init(), context(subject: "bf-admin"))

            #expect(
                output.submitFunnel.map(\.key) == [
                    "grading_start", "runtime_loaded", "setup_unpacked",
                    "suite_started", "suite_done", "result_posting", "result_posted",
                ])
            #expect(output.submitFunnel.map(\.count) == [5, 5, 4, 4, 3, 2, 2])
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

    // MARK: - get_metrics_timeseries

    @Test func getMetricsTimeseriesReturnsBucketsForAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "ts-admin", role: "admin")
            let output = try await GetMetricsTimeseriesTool().execute(
                .init(hours: 6, bucketMinutes: 30), context(subject: "ts-admin"))
            #expect(output.windowHours >= 1)
            #expect(!output.buckets.isEmpty)
        }
    }

    @Test func getMetricsTimeseriesRejectsNonAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "ts-prof", role: "instructor")
            await #expect(throws: MCPToolError.self) {
                _ = try await GetMetricsTimeseriesTool().execute(.init(), context(subject: "ts-prof"))
            }
        }
    }

    // MARK: - get_queue_state

    @Test func getQueueStateCountsPendingAndStuckForAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "qs-admin", role: "admin")
            let course = try await makeTestCourse(on: app, code: "QS101")
            let courseID = try course.requireID()
            let setup = try await makeTestSetup(on: app, id: "qs_setup", courseID: courseID)
            let setupID = try setup.requireID()
            let student = try await makeTestUser(on: app, username: "qs-student", role: "student")
            let studentID = try student.requireID()
            _ = try await makeTestSubmission(
                on: app, id: "qs_pending", setupID: setupID, userID: studentID, status: "pending")
            let stuck = try await makeTestSubmission(
                on: app, id: "qs_stuck", setupID: setupID, userID: studentID, status: "assigned")
            stuck.assignedAt = Date().addingTimeInterval(-700)
            stuck.workerID = "runner-x"
            try await stuck.save(on: app.db)

            let output = try await GetQueueStateTool().execute(.init(), context(subject: "qs-admin"))
            #expect(output.pendingTotal >= 1)
            #expect(output.stuckAssignedCount == 1)
            #expect(output.stuckThresholdSeconds == 600)
            #expect((output.oldestPendingAgeSeconds ?? -1) >= 0)
        }
    }

    @Test func getQueueStateRejectsNonAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "qs-prof", role: "instructor")
            await #expect(throws: MCPToolError.self) {
                _ = try await GetQueueStateTool().execute(.init(), context(subject: "qs-prof"))
            }
        }
    }

    // MARK: - list_runners / get_runner_detail

    @Test func listRunnersReportsActiveRunnerForAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "lr-admin", role: "admin")
            await app.workerActivityStore.markActive(
                workerID: "runner-lr", hostname: "host-lr", runnerVersion: "v9", maxConcurrentJobs: 4)
            let output = try await ListRunnersTool().execute(.init(), context(subject: "lr-admin"))
            #expect(output.activeRunnerCount >= 1)
            #expect(output.runners.contains { $0.workerID == "runner-lr" && $0.hostname == "host-lr" })
        }
    }

    @Test func listRunnersRejectsNonAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "lr-prof", role: "instructor")
            await #expect(throws: MCPToolError.self) {
                _ = try await ListRunnersTool().execute(.init(), context(subject: "lr-prof"))
            }
        }
    }

    @Test func getRunnerDetailAggregatesAndRedactsJobIdentifiers() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "rd-admin", role: "admin")
            let student = try await makeTestUser(on: app, username: "rd-student", role: "student")
            let studentID = try student.requireID()
            let course = try await makeTestCourse(on: app, code: "RD101")
            let courseID = try course.requireID()
            let setup = try await makeTestSetup(on: app, id: "rd_setup", courseID: courseID)
            let setupID = try setup.requireID()
            _ = try await makeTestSubmission(
                on: app, id: "sub_rd_secret", setupID: setupID, userID: studentID)
            await app.workerActivityStore.markActive(
                workerID: "runner-rd", hostname: "host-rd", runnerVersion: "v1", maxConcurrentJobs: 4)
            try await RunnerSnapshot(
                runnerID: "runner-rd", recordedAt: Date(), activeJobs: 1, maxJobs: 4,
                availableCapacity: 3, hostname: "host-rd", runnerVersion: "v1", lastPollAt: Date(),
                lastHeartbeatAt: Date(), serverAssignedJobCountSinceStart: 2
            ).save(on: app.db)
            let job = JobExecutionMetric(
                submissionID: "sub_rd_secret", jobID: "sub_rd_secret", testSetupID: setupID,
                courseID: courseID, assignmentID: nil, userID: studentID, runnerID: "runner-rd",
                kind: "student", attemptNumber: 1, enqueuedAt: Date())
            job.finalStatus = "passed"
            job.executionMs = 1200
            job.queueWaitMs = 150
            job.testSetupCacheHit = true
            job.completedAt = Date()
            try await job.save(on: app.db)

            let output = try await GetRunnerDetailTool().execute(
                .init(runnerID: "runner-rd", sampleSize: nil), context(subject: "rd-admin"))
            #expect(output.runnerID == "runner-rd")
            #expect(output.timing.sampleSize == 1)
            #expect(output.timing.passedCount == 1)
            #expect(output.timing.cacheHitRatePercent == 100)
            #expect(!output.recentSnapshots.isEmpty)

            // PII guarantee: neither the student id nor the submission id appears.
            let json = try #require(String(bytes: JSONEncoder().encode(output), encoding: .utf8))
            #expect(!json.contains(studentID.uuidString))
            #expect(!json.contains("sub_rd_secret"))
            #expect(!json.lowercased().contains("username"))
        }
    }

    @Test func getRunnerDetailRejectsUnknownRunner() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "rd-admin2", role: "admin")
            await #expect(throws: MCPToolError.self) {
                _ = try await GetRunnerDetailTool().execute(
                    .init(runnerID: "nope", sampleSize: nil), context(subject: "rd-admin2"))
            }
        }
    }

    @Test func getRunnerDetailRejectsNonAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "rd-prof", role: "instructor")
            await #expect(throws: MCPToolError.self) {
                _ = try await GetRunnerDetailTool().execute(
                    .init(runnerID: "runner-rd", sampleSize: nil), context(subject: "rd-prof"))
            }
        }
    }

    // MARK: - get_storage_usage

    @Test func getStorageUsageReturnsComponentsForAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "su-admin", role: "admin")
            let output = try await GetStorageUsageTool().execute(.init(), context(subject: "su-admin"))
            // Always at least the five component rows (Submissions … Database).
            #expect(output.rows.count >= 5)
            #expect(output.rows.contains { $0.label == "Database" })
            #expect(!output.dbBackend.isEmpty)
        }
    }

    @Test func getStorageUsageRejectsNonAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "su-prof", role: "instructor")
            await #expect(throws: MCPToolError.self) {
                _ = try await GetStorageUsageTool().execute(.init(), context(subject: "su-prof"))
            }
        }
    }

    // MARK: - get_request_metrics

    @Test func getRequestMetricsAggregatesAndNormalizesPaths() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "rm-admin", role: "admin")
            let now = Date()
            try await APIRequestMetric(
                method: "GET", path: "/api/v1/submissions/sub_abc12345", requestKind: nil,
                statusCode: 200, startedAt: now, finishedAt: now, durationMs: 50,
                submissionID: nil, workerID: nil
            ).save(on: app.db)
            try await APIRequestMetric(
                method: "GET", path: "/api/v1/submissions/sub_def67890", requestKind: nil,
                statusCode: 500, startedAt: now, finishedAt: now, durationMs: 800,
                submissionID: nil, workerID: nil
            ).save(on: app.db)

            let output = try await GetRequestMetricsTool().execute(.init(), context(subject: "rm-admin"))
            #expect(output.total == 2)
            #expect(output.byStatusClass.contains { $0.statusClass == "2xx" && $0.count == 1 })
            #expect(output.byStatusClass.contains { $0.statusClass == "5xx" && $0.count == 1 })
            // Both concrete submission ids collapse to one normalized route.
            let route = try #require(output.slowestRoutes.first { $0.route.contains("/submissions/:id") })
            #expect(route.count == 2)
            #expect(route.errorCount == 1)

            // PII guarantee: concrete submission ids never appear (normalized).
            let json = try #require(String(bytes: JSONEncoder().encode(output), encoding: .utf8))
            #expect(!json.contains("sub_abc12345"))
            #expect(!json.contains("sub_def67890"))
        }
    }

    @Test func getRequestMetricsRejectsNonAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "rm-prof", role: "instructor")
            await #expect(throws: MCPToolError.self) {
                _ = try await GetRequestMetricsTool().execute(.init(), context(subject: "rm-prof"))
            }
        }
    }

    // MARK: - list_connected_agents

    @Test func listConnectedAgentsReturnsGrantsForAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "ca-admin", role: "admin")
            let owner = try await makeTestUser(on: app, username: "ca-owner", role: "instructor")
            let ownerID = try owner.requireID()
            try await MCPOAuthClient(
                clientID: "cli-ca", name: "Test Agent CA", redirectURIs: ["https://x/cb"]
            ).save(on: app.db)
            try await MCPGrant(
                userID: ownerID, clientID: "cli-ca", scope: "content:read",
                refreshTokenHash: "secret-refresh-hash", expiresAt: Date().addingTimeInterval(3600)
            ).save(on: app.db)

            let output = try await ListConnectedAgentsTool().execute(
                .init(includeRevoked: nil), context(subject: "ca-admin"))
            let agent = try #require(output.agents.first { $0.agentName == "Test Agent CA" })
            #expect(agent.scope == "content:read")
            #expect(agent.owner == "ca-owner")

            // The refresh-token hash is never surfaced.
            let json = try #require(String(bytes: JSONEncoder().encode(output), encoding: .utf8))
            #expect(!json.contains("secret-refresh-hash"))
        }
    }

    @Test func listConnectedAgentsRejectsNonAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "ca-prof", role: "instructor")
            await #expect(throws: MCPToolError.self) {
                _ = try await ListConnectedAgentsTool().execute(.init(), context(subject: "ca-prof"))
            }
        }
    }

    // MARK: - get_brightspace_sync_status

    @Test func getBrightSpaceSyncStatusAggregatesAndRedactsStudentGrade() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "bs-admin", role: "admin")
            try await APIBrightSpaceSyncLog(
                courseID: nil, testSetupID: "ts", assignmentTitle: "Lab 1", userID: UUID(),
                username: "bs-secret-student", orgUnitID: "ou1", gradeObjectID: "g1", points: 95.0,
                status: .error, detail: "D2L returned 500"
            ).save(on: app.db)
            try await APIBrightSpaceSyncLog(
                courseID: nil, testSetupID: "ts", assignmentTitle: "Lab 1", userID: UUID(),
                username: "bs-other-student", orgUnitID: "ou1", gradeObjectID: "g1", points: 100.0,
                status: .success, detail: nil
            ).save(on: app.db)

            let output = try await GetBrightSpaceSyncStatusTool().execute(
                .init(), context(subject: "bs-admin"))
            #expect(output.total == 2)
            #expect(output.byStatus.contains { $0.key == "error" && $0.count == 1 })
            #expect(output.byStatus.contains { $0.key == "success" && $0.count == 1 })
            let sample = try #require(output.recentErrors.first)
            #expect(sample.detail == "D2L returned 500")

            // PII guarantee: no student username, no grade (points).
            let json = try #require(String(bytes: JSONEncoder().encode(output), encoding: .utf8))
            #expect(!json.contains("bs-secret-student"))
            #expect(!json.contains("bs-other-student"))
            #expect(!json.lowercased().contains("\"points\""))
            #expect(!json.lowercased().contains("username"))
        }
    }

    @Test func getBrightSpaceSyncStatusRejectsNonAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "bs-prof", role: "instructor")
            await #expect(throws: MCPToolError.self) {
                _ = try await GetBrightSpaceSyncStatusTool().execute(.init(), context(subject: "bs-prof"))
            }
        }
    }

    // MARK: - query_audit_log

    @Test func queryAuditLogCountsByActionAndRedactsActors() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "al-admin", role: "admin")
            try await APIAuditLogEntry(
                actorUserID: nil, actorUsername: "al-secret-actor",
                action: AuditAction.loginFailure.rawValue, remoteAddr: "203.0.113.7"
            ).save(on: app.db)
            try await APIAuditLogEntry(
                actorUsername: "al-admin", action: AuditAction.userRoleChanged.rawValue
            ).save(on: app.db)

            let output = try await QueryAuditLogTool().execute(.init(), context(subject: "al-admin"))
            #expect(output.total == 2)
            #expect(output.byAction.contains { $0.key == "auth.login_failure" && $0.count == 1 })
            #expect(output.byAction.contains { $0.key == "user.role_changed" && $0.count == 1 })
            #expect(output.byCategory.contains { $0.key == "Authentication" && $0.count == 1 })

            // PII guarantee: no actor identity, no IP — counts only.
            let json = try #require(String(bytes: JSONEncoder().encode(output), encoding: .utf8))
            #expect(!json.contains("al-secret-actor"))
            #expect(!json.contains("203.0.113.7"))
        }
    }

    @Test func queryAuditLogRejectsNonAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "al-prof", role: "instructor")
            await #expect(throws: MCPToolError.self) {
                _ = try await QueryAuditLogTool().execute(.init(), context(subject: "al-prof"))
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
                "get_metrics_timeseries", "get_active_users_series", "get_instructor_card_series",
                "get_queue_state", "list_runners", "get_runner_detail", "get_storage_usage",
                "get_request_metrics", "get_health_alerts", "get_browser_diagnostics",
                "list_connected_agents", "get_brightspace_sync_status", "query_logs",
                "query_audit_log",
            ]))
    }
}
