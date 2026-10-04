// Tests/APITests/MCP/MCPSurfacePrincipalTests.swift
//
// `MCPPrincipal` and `AdminMCPPrincipal` are one generic type (#1944), and
// each is stored under a key that is generic over the scope. These tests pin
// that the two surfaces still keep separate slots on one request.

import Core
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct MCPSurfacePrincipalTests {
    @Test func theTwoSurfacesKeepSeparateSlots() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let req = Request(application: app, on: app.eventLoopGroup.any())
            #expect(req.mcpPrincipal == nil)
            #expect(req.adminMcpPrincipal == nil)

            req.mcpPrincipal = MCPPrincipal(subject: "content-agent", grantedScopes: [.read, .write])
            #expect(req.adminMcpPrincipal == nil)

            req.adminMcpPrincipal = AdminMCPPrincipal(subject: "admin-agent", grantedScopes: [.read])
            #expect(req.mcpPrincipal?.subject == "content-agent")
            #expect(req.mcpPrincipal?.grantedScopes == [.read, .write])
            #expect(req.adminMcpPrincipal?.subject == "admin-agent")
            #expect(req.adminMcpPrincipal?.grantedScopes == [.read])

            req.mcpPrincipal = nil
            #expect(req.adminMcpPrincipal?.subject == "admin-agent")
        }
    }

    @Test func theRegistryKeepsTheFirstToolOfAName() {
        let first = AnyDiagnosticTool(
            name: "dup", title: "First", description: "", inputSchema: .null, outputSchema: nil,
            annotations: nil, requiredScopes: [.read], rechecksAdminRole: true,
            invoke: { _, _ in .null })
        let second = AnyDiagnosticTool(
            name: "dup", title: "Second", description: "", inputSchema: .null, outputSchema: nil,
            annotations: nil, requiredScopes: [.read], rechecksAdminRole: true,
            invoke: { _, _ in .null })
        let other = AnyDiagnosticTool(
            name: "abc", title: "Other", description: "", inputSchema: .null, outputSchema: nil,
            annotations: nil, requiredScopes: [.read], rechecksAdminRole: true,
            invoke: { _, _ in .null })
        let registry = DiagnosticToolRegistry([first, second, other])
        #expect(registry.all.map(\.name) == ["abc", "dup"])
        #expect(registry.tool(named: "dup")?.title == "First")
        #expect(registry.tool(named: "missing") == nil)
    }
}
