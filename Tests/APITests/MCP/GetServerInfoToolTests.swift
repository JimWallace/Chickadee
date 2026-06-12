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

    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.read])
    }

    @Test func reportsCurrentVersion() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let out = try await GetServerInfoTool().execute(GetServerInfoTool.Input(), context(app))
            #expect(out.version == ChickadeeVersion.current)
        }
    }

    @Test func reportsReadWriteModeAndScopes() async throws {
        let app = try await makeTestApp(appConfig: .testDefaults(mcp: mcpConfig(.readWrite)))
        try await withApp(app) { app in
            let out = try await GetServerInfoTool().execute(GetServerInfoTool.Input(), context(app))
            #expect(out.mcpMode == "read_write")
            #expect(out.writeEnabled)
            #expect(out.advertisedScopes == ["content:read", "content:write"])
        }
    }

    @Test func reportsReadOnlyModeWithoutWrite() async throws {
        let app = try await makeTestApp(appConfig: .testDefaults(mcp: mcpConfig(.readOnly)))
        try await withApp(app) { app in
            let out = try await GetServerInfoTool().execute(GetServerInfoTool.Input(), context(app))
            #expect(out.mcpMode == "read_only")
            #expect(!out.writeEnabled)
            #expect(out.advertisedScopes == ["content:read"])
        }
    }
}
