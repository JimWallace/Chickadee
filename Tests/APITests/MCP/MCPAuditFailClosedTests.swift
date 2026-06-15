// Verifies the audit fail-closed policy (P1-2): a WRITE tool must not mutate
// state unless its audit record persists first, while a READ tool degrades to
// best-effort and still succeeds. Audit-write failure is simulated by dropping
// the audit_log table in the per-test database.

import Core
import Fluent
import Testing
import Vapor

@testable import APIServer

@Suite struct MCPAuditFailClosedTests {
    private func dispatcher() -> MCPDispatcher {
        MCPDispatcher(
            serverInfo: MCPServerInfo(name: "t", version: "t"),
            tools: ToolRegistry([UpdateAssignmentTool().erased(), GetAssignmentTool().erased()]))
    }

    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "jsmith", grantedScopes: [.read, .write],
            actingClientID: "agent-1", actingClientName: "Claude Bot")
    }

    private func fixture(on app: Application) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let prof = try await makeTestUser(on: app, username: "jsmith", role: "instructor")
        try await makeTestEnrollment(on: app, userID: prof.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_a", courseID: courseID)
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_a", courseID: courseID, title: "Original")
    }

    private func updateCall(_ publicID: String, title: String) -> JSONRPCRequest {
        JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object([
                "name": .string("update_assignment"),
                "arguments": .object([
                    "assignmentPublicID": .string(publicID), "title": .string(title),
                ]),
            ]))
    }

    private func reloadTitle(_ app: Application, _ publicID: String) async throws -> String {
        try #require(
            await APIAssignment.query(on: app.db).filter(\.$publicID == publicID).first()
        ).title
    }

    @Test func writeToolFailsClosedWhenAuditCannotPersist() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            // Force the pre-write audit to fail by removing its table.
            try await app.db.schema("audit_log").delete()

            let response = try #require(
                await dispatcher().dispatch(
                    updateCall(assignment.publicID, title: "Changed"), context: context(app)))

            // Fail closed: an error is returned and the write never applied.
            #expect(response.error != nil)
            #expect(try await reloadTitle(app, assignment.publicID) == "Original")
        }
    }

    @Test func readToolStillSucceedsWhenAuditCannotPersist() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            try await app.db.schema("audit_log").delete()

            let request = JSONRPCRequest(
                jsonrpc: "2.0", id: .number(1), method: "tools/call",
                params: .object([
                    "name": .string("get_assignment"),
                    "arguments": .object(["assignmentPublicID": .string(assignment.publicID)]),
                ]))
            let response = try #require(await dispatcher().dispatch(request, context: context(app)))

            // Reads degrade to best-effort audit; the read still succeeds.
            #expect(response.error == nil)
        }
    }

    @Test func writeToolRecordsSingleRowWithOutcomeWhenAuditHealthy() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)

            _ = try #require(
                await dispatcher().dispatch(
                    updateCall(assignment.publicID, title: "Changed"), context: context(app)))

            let rows = try await APIAuditLogEntry.query(on: app.db)
                .filter(\.$action == "mcp.tool_called").all()
            #expect(rows.count == 1)  // pre-write row, stamped with outcome (not a second row)
            let row = try #require(rows.first)
            #expect(row.targetID == assignment.publicID)
            #expect(row.metadata?.contains("\"outcome\":\"success\"") == true)
            #expect(try await reloadTitle(app, assignment.publicID) == "Changed")
        }
    }
}
