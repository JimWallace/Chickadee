// Tests/APITests/MCP/MCPBoundedIntTests.swift
//
// Bounded integer arguments render their range from one value, and query_logs
// refuses an unknown level instead of ignoring it (#2336).

import Core
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct MCPBoundedIntTests {
    private let bound = MCPBoundedInt(default: 20, max: 100)

    @Test func resolveUsesTheDefaultAndClampsToTheRange() {
        #expect(bound.resolve(nil) == 20)
        #expect(bound.resolve(0) == 1)
        #expect(bound.resolve(-5) == 1)
        #expect(bound.resolve(50) == 50)
        #expect(bound.resolve(1_000) == 100)
    }

    @Test func thePropertyDeclaresTheRangeAndStatesItInProse() {
        #expect(
            bound.property("Max entries")
                == .object([
                    "type": .string("integer"),
                    "description": .string("Max entries (default 20, max 100)."),
                    "minimum": .int(1),
                    "maximum": .int(100),
                ]))
    }

    @Test func queryLogsRefusesAnUnknownLevel() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "ql-admin", role: "admin")
            let context = AdminToolContext(
                request: Request(application: app, on: app.eventLoopGroup.any()),
                subject: "ql-admin", grantedScopes: [.read])
            await #expect(throws: MCPToolError.self) {
                _ = try await QueryLogsTool().execute(.init(minLevel: "warn"), context)
            }
            _ = try await QueryLogsTool().execute(.init(minLevel: "ERROR"), context)
        }
    }
}
