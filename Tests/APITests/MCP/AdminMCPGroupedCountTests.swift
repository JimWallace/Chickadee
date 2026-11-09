// Tests/APITests/MCP/AdminMCPGroupedCountTests.swift
//
// get_request_metrics and query_audit_log count in the database: identical
// rows arrive as one group with a count. Each group must still count once
// per row, in the totals and in the duration percentiles.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AdminMCPGroupedCountTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "admin-mcp-grouped")
    }

    private func context(subject: String) -> AdminToolContext {
        AdminToolContext(request: makeTestRequest(on: app), subject: subject, grantedScopes: [.read])
    }

    private func metric(_ path: String, status: Int, durationMs: Int) -> APIRequestMetric {
        let now = Date()
        return APIRequestMetric(
            method: "GET", path: path, requestKind: nil, statusCode: status, startedAt: now, finishedAt: now,
            durationMs: durationMs, submissionID: nil, workerID: nil)
    }

    @Test func identicalRequestsCountOncePerRow() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "grp-admin", role: "admin")
            // Nineteen slow requests that group into one row, and one fast
            // one. The median of the twenty is the slow value; counted as two
            // groups without their weights it would be the fast one.
            for _ in 0..<19 {
                try await metric("/api/v1/submissions/sub_aaaaaaaa", status: 200, durationMs: 900).save(on: app.db)
            }
            try await metric("/api/v1/submissions/sub_bbbbbbbb", status: 500, durationMs: 10).save(on: app.db)

            let output = try await GetRequestMetricsTool().execute(.init(), context(subject: "grp-admin"))
            #expect(output.total == 20)
            #expect(output.byStatusClass.contains { $0.statusClass == "2xx" && $0.count == 19 })
            #expect(output.byStatusClass.contains { $0.statusClass == "5xx" && $0.count == 1 })
            let route = try #require(output.slowestRoutes.first { $0.route.contains("/submissions/:id") })
            #expect(route.count == 20)
            #expect(route.errorCount == 1)
            #expect(route.maxMs == 900)
            #expect(output.overall.p50Ms == 900)
        }
    }

    @Test func repeatedAuditActionsCountOncePerEntry() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "grp-audit", role: "admin")
            for _ in 0..<3 {
                try await APIAuditLogEntry(
                    actorUsername: "someone", action: AuditAction.loginFailure.rawValue
                ).save(on: app.db)
            }
            try await APIAuditLogEntry(
                actorUsername: "grp-audit", action: AuditAction.userRoleChanged.rawValue
            ).save(on: app.db)

            let all = try await QueryAuditLogTool().execute(.init(), context(subject: "grp-audit"))
            #expect(all.total == 4)
            #expect(all.byAction.contains { $0.key == "auth.login_failure" && $0.count == 3 })
            #expect(all.byAction.contains { $0.key == "user.role_changed" && $0.count == 1 })

            let filtered = try await QueryAuditLogTool().execute(
                .init(action: AuditAction.loginFailure.rawValue), context(subject: "grp-audit"))
            #expect(filtered.total == 3)
            #expect(filtered.byAction.count == 1)
        }
    }
}
