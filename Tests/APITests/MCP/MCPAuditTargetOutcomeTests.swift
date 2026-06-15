// Verifies MCP tool-call audit records carry the target resource (assignment
// public ID / course code) and the call outcome, and never the tool arguments.
// Complements MCPAuditAttributionTests, which covers the `<username>-MCP` actor.

import Core
import Fluent
import Testing
import Vapor

@testable import APIServer

@Suite struct MCPAuditTargetOutcomeTests {
    private func dispatcher() -> MCPDispatcher {
        MCPDispatcher(
            serverInfo: MCPServerInfo(name: "t", version: "t"),
            tools: ToolRegistry([GetAssignmentTool().erased(), ListAssignmentsTool().erased()]))
    }

    private func context(_ app: Application, subject: String) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: subject, grantedScopes: [.read],
            actingClientID: "agent-1", actingClientName: "Claude Bot")
    }

    private func auditRows(_ app: Application) async throws -> [APIAuditLogEntry] {
        try await APIAuditLogEntry.query(on: app.db)
            .filter(\.$action == "mcp.tool_called").all()
    }

    private func toolCall(_ name: String, _ arguments: JSONValue) -> JSONRPCRequest {
        JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object(["name": .string(name), "arguments": arguments]))
    }

    @Test func recordsAssignmentTargetAndSuccessOutcome() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            let prof = try await makeTestUser(on: app, username: "jsmith", role: "instructor")
            try await makeTestEnrollment(on: app, userID: prof.requireID(), courseID: courseID)
            try await makeTestSetup(on: app, id: "setup_a", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_a", courseID: courseID, title: "Tasks")

            let request = toolCall(
                "get_assignment", .object(["assignmentPublicID": .string(assignment.publicID)]))
            _ = try #require(await dispatcher().dispatch(request, context: context(app, subject: "jsmith")))

            let rows = try await auditRows(app)
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row.actorUsername == "jsmith-MCP")
            #expect(row.targetType == "assignment")
            #expect(row.targetID == assignment.publicID)
            #expect(row.metadata?.contains("\"outcome\":\"success\"") == true)
        }
    }

    @Test func recordsNotAuthorizedOutcomeWhenUnenrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            // Subject exists but is NOT enrolled in the course.
            _ = try await makeTestUser(on: app, username: "outsider", role: "instructor")
            try await makeTestSetup(on: app, id: "setup_a", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_a", courseID: courseID, title: "Tasks")

            let request = toolCall(
                "get_assignment", .object(["assignmentPublicID": .string(assignment.publicID)]))
            _ = try #require(
                await dispatcher().dispatch(request, context: context(app, subject: "outsider")))

            let row = try #require(try await auditRows(app).first)
            #expect(row.targetID == assignment.publicID)
            #expect(row.metadata?.contains("\"outcome\":\"not_authorized\"") == true)
        }
    }

    @Test func neverLogsToolArguments() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            let prof = try await makeTestUser(on: app, username: "jsmith", role: "instructor")
            try await makeTestEnrollment(on: app, userID: prof.requireID(), courseID: courseID)
            try await makeTestSetup(on: app, id: "setup_a", courseID: courseID)
            _ = try await makeTestAssignment(
                on: app, testSetupID: "setup_a", courseID: courseID, title: "Tasks")

            // An extra argument the tool ignores; it must never reach the audit row.
            let secret = "SECRET_SCRIPT_BODY_DO_NOT_LOG"
            let request = toolCall(
                "list_assignments",
                .object(["courseCode": .string("CS246"), "content": .string(secret)]))
            _ = try #require(await dispatcher().dispatch(request, context: context(app, subject: "jsmith")))

            let row = try #require(try await auditRows(app).first)
            #expect(row.targetType == "course")
            #expect(row.targetID == "CS246")
            #expect(row.metadata?.contains(secret) != true)
            #expect(row.targetID?.contains(secret) != true)
        }
    }
}
