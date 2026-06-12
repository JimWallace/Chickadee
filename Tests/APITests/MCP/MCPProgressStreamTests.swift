// End-to-end tests for the validate_assignment live-progress SSE stream: a
// tools/call carrying a progressToken over an SSE connection emits
// notifications/progress before the final result; without a token it falls back
// to a single result event.

import Fluent
import JWT
import Testing
import XCTVapor

@testable import APIServer

@Suite struct MCPProgressStreamTests {
    private let issuer = "https://chickadee.example"
    private let resource = "https://chickadee.example/mcp"

    private func makeMCPApp() async throws -> (Application, MCPTokenAuthority) {
        let mcp = MCPConfig(
            mode: .readWrite, allowedHosts: [], allowedOrigins: [],
            tokenTTLSeconds: 3600, signingKeyPath: "unused",
            issuer: issuer, resource: resource)
        let app = try await makeTestApp(appConfig: .testDefaults(mcp: mcp))
        let authority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
        app.mcpTokenAuthority = authority
        return (app, authority)
    }

    /// Enrolled agent + a setup + an assignment already in a terminal validation
    /// state, so the watch completes immediately (one progress event + result).
    private func passedAssignment(on app: Application) async throws -> String {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let agent = try await makeTestUser(on: app, username: "agent", role: "mcp")
        try await makeTestEnrollment(on: app, userID: agent.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_ps", courseID: courseID)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "setup_ps", courseID: courseID, title: "Lab")
        assignment.validationStatus = "passed"
        try await assignment.save(on: app.db)
        return assignment.publicID
    }

    private func post(
        _ app: Application, body: String, token: String, accept: String
    ) async throws -> XCTHTTPResponse {
        try await app.asyncSendRequest(
            .POST, "/mcp",
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(token)",
                "Accept": accept,
            ],
            body: ByteBuffer(string: body))
    }

    @Test func streamsProgressThenResultWithToken() async throws {
        let (app, authority) = try await makeMCPApp()
        try await withApp(app) { app in
            let publicID = try await passedAssignment(on: app)
            let token = try await authority.mint(
                subject: "agent", scopes: [.read, .write],
                issuer: issuer, audience: resource, ttlSeconds: 3600)
            // progressToken in params._meta opts the call into live progress.
            let body = """
                {"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"validate_assignment",\
                "arguments":{"assignmentPublicID":"\(publicID)","timeoutSeconds":5},\
                "_meta":{"progressToken":"p-1"}}}
                """
            let res = try await post(app, body: body, token: token, accept: "text/event-stream")

            #expect(res.status == .ok)
            #expect(res.headers.contentType?.description.contains("text/event-stream") == true)
            let text = res.body.string
            // At least one progress notification, echoing the token, then the
            // final tool result carrying the passed status. (JSONEncoder escapes
            // the method's slash as `notifications\/progress`, so match the
            // method name + token rather than the literal slashed string.)
            #expect(text.contains("notifications"))
            #expect(text.contains("\"progressToken\":\"p-1\""))
            #expect(text.contains("\"validationStatus\":\"passed\""))
            #expect(text.contains("\"isError\":false"))
        }
    }

    @Test func withoutTokenEmitsSingleResultEvent() async throws {
        let (app, authority) = try await makeMCPApp()
        try await withApp(app) { app in
            let publicID = try await passedAssignment(on: app)
            let token = try await authority.mint(
                subject: "agent", scopes: [.read, .write],
                issuer: issuer, audience: resource, ttlSeconds: 3600)
            // No _meta.progressToken → generic SSE path: single result event, no
            // progress notifications.
            let body = """
                {"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"validate_assignment",\
                "arguments":{"assignmentPublicID":"\(publicID)","timeoutSeconds":5}}}
                """
            let res = try await post(app, body: body, token: token, accept: "text/event-stream")

            #expect(res.status == .ok)
            let text = res.body.string
            #expect(!text.contains("notifications"))
            #expect(!text.contains("progressToken"))
            #expect(text.contains("\"validationStatus\":\"passed\""))
        }
    }
}
