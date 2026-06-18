// Tests for the admin diagnostic MCP surface (docs/admin-mcp.md): the
// AdminMCPDispatcher (lifecycle, tools-only capabilities, scope-gated
// tools/list, tools/call), the get_deployment_info tool, and the
// AdminToolContext.requireAdminSubject gate.  The surface is tied to MCP_MODE
// (no ADMIN_MCP_* settings) and is always read-only.
//
// Distinct from AdminMCPRoutesTests, which covers the unrelated /admin/mcp web
// page that manages content-MCP service accounts.

import Core
import Fluent
import Testing
import Vapor
import XCTVapor

@testable import APIServer

// MARK: - Dispatcher (pure logic, no app)

@Suite struct AdminMCPDispatcherLogicTests {
    private let dispatcher = AdminMCPDispatcher(
        serverInfo: MCPServerInfo(name: "Chickadee Admin MCP", version: "test-9.9.9"),
        tools: AdminMCPToolCatalog.live
    )

    private func request(
        _ method: String, id: JSONRPCID? = .number(1), params: JSONValue? = nil
    ) -> JSONRPCRequest {
        JSONRPCRequest(jsonrpc: "2.0", id: id, method: method, params: params)
    }

    @Test func initializeAdvertisesToolsOnlyAndAdminInstructions() async throws {
        let response = try #require(await dispatcher.dispatch(request("initialize")))
        let result = try #require(response.result?.objectFields)

        let caps = try #require(result["capabilities"]?.objectFields)
        #expect(caps["tools"] == .object(["listChanged": .bool(false)]))
        // Tools-only surface: the resources capability is omitted from the wire.
        #expect(caps["resources"] == nil)

        let info = try #require(result["serverInfo"]?.objectFields)
        #expect(info["name"] == .string("Chickadee Admin MCP"))

        let instructions = try #require(result["instructions"]?.stringValue)
        #expect(instructions.contains("ADMIN DIAGNOSTIC"))
        #expect(instructions.contains("NEVER exposes student data"))
        #expect(instructions.contains("Read-only"))
    }

    @Test func toolsListIncludesGetDeploymentInfoAsReadOnly() async throws {
        let response = try #require(await dispatcher.dispatch(request("tools/list")))
        let tools = try #require(response.result?.objectFields?["tools"]?.arrayValue)
        let tool = try #require(
            tools.first { $0.objectFields?["name"]?.stringValue == "get_deployment_info" })
        let annotations = try #require(tool.objectFields?["annotations"]?.objectFields)
        #expect(annotations["readOnlyHint"] == .bool(true))
    }

    @Test func pingReturnsEmptyObject() async throws {
        let response = try #require(await dispatcher.dispatch(request("ping")))
        #expect(response.result == .object([:]))
    }

    @Test func unknownMethodIsMethodNotFound() async throws {
        let response = try #require(await dispatcher.dispatch(request("does/not/exist")))
        #expect(response.error?.code == -32_601)
    }

    @Test func resourcesAreNotSupported() async throws {
        // The admin surface advertises tools only, so resource methods are
        // method-not-found here (the content surface implements them).
        let response = try #require(await dispatcher.dispatch(request("resources/list")))
        #expect(response.error?.code == -32_601)
    }

    @Test func notificationGetsNoResponse() async throws {
        let response = await dispatcher.dispatch(request("initialized", id: nil))
        #expect(response == nil)
    }
}

// MARK: - Tool execution + admin gate (app-backed)

@Suite(.serialized) final class AdminMCPToolExecutionTests {
    let app: Application
    let dispatcher: AdminMCPDispatcher

    init() async throws {
        app = try await makeTestApp(prefix: "admin-mcp")
        dispatcher = AdminMCPDispatcher(
            serverInfo: MCPServerInfo(name: "Chickadee Admin MCP", version: "test"),
            tools: AdminMCPToolCatalog.live)
    }

    private func context(
        _ scopes: Set<DiagnosticScope>, subject: String = "root"
    ) -> AdminToolContext {
        AdminToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: subject,
            grantedScopes: scopes)
    }

    private func toolCall(_ name: String) -> JSONRPCRequest {
        JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object(["name": .string(name)]))
    }

    @Test func getDeploymentInfoReturnsVersionAndModes() async throws {
        try await withApp(app) { _ in
            let response = try #require(
                await dispatcher.dispatch(toolCall("get_deployment_info"), context: context([.read])))
            let result = try #require(response.result?.objectFields)
            #expect(result["isError"] == .bool(false))

            let structured = try #require(result["structuredContent"]?.objectFields)
            #expect(structured["version"]?.stringValue == ChickadeeVersion.current)
            // Test app defaults: both MCP surfaces off.
            #expect(structured["adminMcpMode"]?.stringValue == "off")
            #expect(structured["contentMcpMode"]?.stringValue == "off")
            #expect(structured["environment"] != nil)
        }
    }

    @Test func toolCallWithoutReadScopeIsRejected() async throws {
        try await withApp(app) { _ in
            // No granted scopes → insufficient scope, surfaced as a JSON-RPC
            // error (not an isError tool result), which the transport maps to 403.
            let response = try #require(
                await dispatcher.dispatch(toolCall("get_deployment_info"), context: context([])))
            #expect(response.error != nil)
            #expect(response.result == nil)
        }
    }

    @Test func toolsListHidesToolsWhenScopeMissing() async throws {
        try await withApp(app) { _ in
            let response = try #require(
                await dispatcher.dispatch(
                    JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "tools/list", params: nil),
                    context: context([])))
            let tools = try #require(response.result?.objectFields?["tools"]?.arrayValue)
            #expect(tools.isEmpty)
        }
    }

    @Test func requireAdminSubjectAcceptsAdminRejectsOthers() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "the-admin", role: "admin")
            _ = try await makeTestUser(on: app, username: "the-prof", role: "instructor")
            _ = try await makeTestUser(on: app, username: "the-student", role: "student")

            let admin = try await context([.read], subject: "the-admin").requireAdminSubject(tool: "x")
            #expect(admin.username == "the-admin")

            for subject in ["the-prof", "the-student", "nobody-at-all"] {
                let ctx = context([.read], subject: subject)
                await #expect(throws: MCPToolError.self) {
                    try await ctx.requireAdminSubject(tool: "x")
                }
            }
        }
    }
}

// MARK: - Test helpers

private extension JSONValue {
    var objectFields: [String: JSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
    var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }
}
