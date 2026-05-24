// Verifies MCP tool calls are recorded in the audit log under a distinct
// `<username>-MCP` actor, so agent-made changes are tracked separately from the
// human's own web actions.

import Core
import Fluent
import Testing
import Vapor

@testable import APIServer

@Suite struct MCPAuditAttributionTests {
    @Test func toolCallIsAuditedAsUsernameMCP() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            let prof = try await makeTestUser(on: app, username: "jsmith", role: "instructor")
            try await makeTestEnrollment(on: app, userID: prof.requireID(), courseID: courseID)
            try await makeTestSetup(on: app, id: "setup_a", courseID: courseID)
            try await makeTestAssignment(
                on: app, testSetupID: "setup_a", courseID: courseID, title: "Tasks")

            let registry = ToolRegistry([ListAssignmentsTool().erased()])
            let dispatcher = MCPDispatcher(serverInfo: MCPServerInfo(name: "t", version: "t"), tools: registry)
            let context = ToolContext(
                request: Request(application: app, on: app.eventLoopGroup.any()),
                subject: "jsmith", grantedScopes: [.read],
                actingClientID: "agent-1", actingClientName: "Claude Bot")
            let request = JSONRPCRequest(
                jsonrpc: "2.0", id: .number(1), method: "tools/call",
                params: .object([
                    "name": .string("list_assignments"),
                    "arguments": .object(["courseCode": .string("CS246")]),
                ]))
            _ = try #require(await dispatcher.dispatch(request, context: context))

            let entry = try #require(
                try await APIAuditLogEntry.query(on: app.db)
                    .filter(\.$action == "mcp.tool_called")
                    .first())
            // Tracked separately from the human's own actions.
            #expect(entry.actorUsername == "jsmith-MCP")
        }
    }
}
