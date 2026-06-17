// Tests for the Phase-3 admin diagnostic tools: get_metrics_snapshot and
// get_health_alerts.  Both wrap PII-free operational aggregates and enforce
// admin-only access via AdminToolContext.requireAdminSubject.

import Core
import Fluent
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
}

// Pure-logic catalog check — no app, so kept out of the class suite (which would
// otherwise build and leak a Vapor app for a test that doesn't need one).
@Suite struct AdminMCPCatalogTests {
    @Test func toolsAreRegistered() {
        let names = Set(AdminMCPToolCatalog.live.all.map(\.name))
        #expect(
            names.isSuperset(of: [
                "get_deployment_info", "get_metrics_snapshot", "get_health_alerts",
            ]))
    }
}
