// Tests/APITests/MCP/MCPProgressStreamAuditTests.swift
//
// The `validate_assignment` progress stream reads on the same pool as every
// other MCP read, and its audit row records the outcome (#2335). The stream is
// built outside the generic dispatcher, so it had neither.

import Fluent
import JWT
import Testing
import VaporTesting

@testable import APIServer

@Suite struct MCPProgressStreamAuditTests {
    private let issuer = "https://chickadee.example"
    private let resource = "https://chickadee.example/mcp"

    @Test func mcpReadsUseTheDefaultPoolUntilADedicatedOneIsConfigured() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            #expect(app.mcpDatabaseID == nil)
            app.usesDedicatedMCPDatabase = true
            #expect(app.mcpDatabaseID == .mcp)
        }
    }

    @Test func theStreamedCallsAuditRowRecordsItsOutcome() async throws {
        let mcp = MCPConfig(
            mode: .readWrite, allowedHosts: [], allowedOrigins: [],
            tokenTTLSeconds: 3600, signingKeyPath: "unused",
            issuer: issuer, resource: resource)
        let app = try await makeTestApp(appConfig: .testDefaults(mcp: mcp))
        let authority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
        app.mcpTokenAuthority = authority
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            let agent = try await makeTestUser(on: app, username: "agent", role: "mcp")
            try await makeTestEnrollment(on: app, userID: agent.requireID(), courseID: courseID)
            try await makeTestSetup(on: app, id: "setup_audit", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_audit", courseID: courseID, title: "Lab")
            assignment.validationStatus = "passed"
            try await assignment.save(on: app.db)

            let token = try await authority.mint(
                subject: "agent", scopes: [.read, .write],
                issuer: issuer, audience: resource, ttlSeconds: 3600)
            let body = """
                {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"validate_assignment",\
                "arguments":{"assignmentPublicID":"\(assignment.publicID)","timeoutSeconds":5},\
                "_meta":{"progressToken":"p-1"}}}
                """
            let res = try await app.asyncSendRequest(
                .POST, "/mcp",
                headers: [
                    "Content-Type": "application/json",
                    "Authorization": "Bearer \(token)",
                    "Accept": "text/event-stream",
                ],
                body: ByteBuffer(string: body))
            #expect(res.body.string.contains("\"validationStatus\":\"passed\""))

            let rows = try await APIAuditLogEntry.query(on: app.db)
                .filter(\.$action == AuditAction.mcpToolCalled.rawValue)
                .all()
            #expect(rows.count == 1)
            let metadata = try #require(rows.first?.metadataDictionary)
            #expect(metadata["tool"] == "validate_assignment")
            #expect(metadata["outcome"] == "success")
        }
    }
}
