// Tests/APITests/MCP/AdminMCPAdminRecheckTests.swift
//
// The admin re-check runs in `AdminMCPDispatcher` for every tool that does not
// opt out (#1943). It used to be a line each tool had to remember, and a tool
// that forgot it was protected only by the bearer layer. The per-tool
// `…RejectsNonAdmin` tests in AdminMCPToolsTests call `execute` directly and
// still pass; these tests go through the dispatcher.

import ChickadeeTestSupport
import Core
import Fluent
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite struct AdminMCPAdminRecheckCatalogTests {
    /// The tools that state they skip the re-check. Adding one is a decision a
    /// reviewer should see, so this list is exact.
    @Test func onlyGetDeploymentInfoOptsOut() {
        let optedOut = AdminMCPToolCatalog.live.all.filter { !$0.rechecksAdminRole }.map(\.name)
        #expect(optedOut == ["get_deployment_info"])
    }
}

@Suite(.serialized, .timeLimit(.minutes(2))) final class AdminMCPAdminRecheckTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "admin-mcp-recheck")
    }

    @Test(arguments: AdminMCPToolCatalog.live.all.filter(\.rechecksAdminRole).map(\.name))
    func everyRecheckingToolRefusesANonAdmin(tool: String) async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "recheck-prof", role: "instructor")
            let dispatcher = AdminMCPDispatcher(
                serverInfo: MCPServerInfo(name: "Chickadee Admin MCP", version: "test"),
                tools: AdminMCPToolCatalog.live)

            let result = try await callResult(
                dispatcher, tool: tool, subject: "recheck-prof", app: app)

            #expect(result.isError)
            #expect(result.text.hasPrefix("Not authorized for \(tool)"))
        }
    }

    /// The case the flag exists for: a tool whose own body never checks.
    @Test func aToolThatForgetsTheCheckIsStillRefusedForANonAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "forgetful-prof", role: "instructor")
            _ = try await makeTestUser(on: app, username: "forgetful-admin", role: "admin")
            let dispatcher = AdminMCPDispatcher(
                serverInfo: MCPServerInfo(name: "Chickadee Admin MCP", version: "test"),
                tools: DiagnosticToolRegistry([ForgetfulTool().erased()]))

            let refused = try await callResult(
                dispatcher, tool: ForgetfulTool.name, subject: "forgetful-prof", app: app)
            let allowed = try await callResult(
                dispatcher, tool: ForgetfulTool.name, subject: "forgetful-admin", app: app)

            #expect(refused.isError)
            #expect(!allowed.isError)
        }
    }

    @Test func aToolThatOptsOutRunsForANonAdmin() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "optout-prof", role: "instructor")
            let dispatcher = AdminMCPDispatcher(
                serverInfo: MCPServerInfo(name: "Chickadee Admin MCP", version: "test"),
                tools: DiagnosticToolRegistry([OptedOutTool().erased()]))

            let result = try await callResult(
                dispatcher, tool: OptedOutTool.name, subject: "optout-prof", app: app)

            #expect(!result.isError)
        }
    }

    // MARK: - Helpers

    private struct CallResult {
        let isError: Bool
        let text: String
    }

    private func callResult(
        _ dispatcher: AdminMCPDispatcher, tool: String, subject: String, app: Application
    ) async throws -> CallResult {
        let context = AdminToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: subject,
            grantedScopes: Set(DiagnosticScope.allCases))
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object(["name": .string(tool), "arguments": .object([:])]))
        let response = try #require(await dispatcher.dispatch(request, context: context))
        guard case .object(let fields) = try #require(response.result) else {
            throw IssueRecorded("tools/call returned no result object")
        }
        var text = ""
        if case .array(let content) = fields["content"],
            case .object(let first) = content.first,
            case .string(let value) = first["text"]
        {
            text = value
        }
        return CallResult(isError: fields["isError"] == .bool(true), text: text)
    }
}

/// A tool whose body does not call `requireAdminSubject`.
private struct ForgetfulTool: DiagnosticTool {
    struct Input: Decodable, Sendable {}
    struct Output: Encodable, Sendable { let ran: Bool }
    static let name = "forgetful_tool"
    static let description = "Test tool that runs no admin check of its own."
    static let inputSchema: JSONValue = MCPSchema.noArgumentsInput

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        Output(ran: true)
    }
}

/// A tool that opts out of the dispatcher's re-check, as get_deployment_info does.
private struct OptedOutTool: DiagnosticTool {
    struct Input: Decodable, Sendable {}
    struct Output: Encodable, Sendable { let ran: Bool }
    static let name = "opted_out_tool"
    static let description = "Test tool that opts out of the admin re-check."
    static let inputSchema: JSONValue = MCPSchema.noArgumentsInput
    static let rechecksAdminRole = false

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        Output(ran: true)
    }
}
