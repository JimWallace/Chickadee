// Tests for GetServerInfoTool (deployed version + MCP capability probe).

import Core
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct GetServerInfoToolTests {
    private func mcpConfig(_ mode: MCPMode) -> MCPConfig {
        MCPConfig(
            mode: mode, allowedHosts: [], allowedOrigins: [],
            tokenTTLSeconds: 3600, signingKeyPath: "unused",
            issuer: "https://chickadee.example", resource: "https://chickadee.example/mcp")
    }

    @Test func reportsCurrentVersion() async throws {
        try await withTestApp { app in
            let out = try await GetServerInfoTool().execute(GetServerInfoTool.Input(), mcpContext(app))
            #expect(out.version == ChickadeeVersion.current)
        }
    }

    @Test func reportsReadWriteModeAndScopes() async throws {
        try await withTestApp(appConfig: .testDefaults(mcp: mcpConfig(.readWrite))) { app in
            let out = try await GetServerInfoTool().execute(GetServerInfoTool.Input(), mcpContext(app))
            #expect(out.mcpMode == "read_write")
            #expect(out.writeEnabled)
            #expect(out.advertisedScopes == ["content:read", "content:write", "feedback:read", "feedback:write"])
        }
    }

    @Test func reportsReadOnlyModeWithoutWrite() async throws {
        try await withTestApp(appConfig: .testDefaults(mcp: mcpConfig(.readOnly))) { app in
            let out = try await GetServerInfoTool().execute(GetServerInfoTool.Input(), mcpContext(app))
            #expect(out.mcpMode == "read_only")
            #expect(!out.writeEnabled)
            #expect(out.advertisedScopes == ["content:read", "feedback:read"])
        }
    }
}
