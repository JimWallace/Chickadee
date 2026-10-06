// Tests/APITests/MCP/MCPErrorPolicyTests.swift
//
// Both MCP surfaces apply one error policy (#2338): a client refusal (4xx)
// reaches the agent with its reason; a server fault (5xx) stays opaque, so the
// dispatcher logs it. The admin erasure used to map nothing.

import Core
import Testing
import Vapor

@testable import APIServer

@Suite struct MCPErrorPolicyTests {
    /// An admin tool that throws the error it was built with.
    private struct RefusingDiagnosticTool: DiagnosticTool {
        struct Input: Decodable, Sendable {}
        struct Output: Encodable, Sendable {}

        static let name = "refuse"
        static let description = "Throws the error it was built with."
        static let inputSchema: JSONValue = .object(["type": .string("object")])
        static let requiredScopes: Set<DiagnosticScope> = [.read]

        let failure: any Error

        func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
            throw failure
        }
    }

    private static func invokeAdmin(throwing failure: any Error) async throws {
        try await withApp(try await Application.make(.testing)) { app in
            let context = AdminToolContext(
                request: Request(application: app, on: app.eventLoopGroup.any()),
                subject: "admin", grantedScopes: [.read])
            _ = try await RefusingDiagnosticTool(failure: failure).erased().invoke(.object([:]), context)
        }
    }

    @Test func anAdminToolsWebRefusalReachesTheAgentWithItsReason() async throws {
        await #expect(throws: MCPToolError.invalidArguments(detail: "bad window")) {
            try await Self.invokeAdmin(throwing: Abort(.badRequest, reason: "bad window"))
        }
    }

    @Test func anAdminToolsServerFaultIsNotMapped() async throws {
        await #expect {
            try await Self.invokeAdmin(throwing: Abort(.internalServerError, reason: "disk full"))
        } throws: { error in
            !(error is MCPToolError)
        }
    }

    @Test(arguments: [
        (HTTPResponseStatus.badRequest, true), (.forbidden, true), (.conflict, true),
        (.internalServerError, false), (.serviceUnavailable, false),
    ])
    func onlyA4xxIsAClientRefusal(status: HTTPResponseStatus, expected: Bool) {
        #expect(Abort(status).isClientRefusal == expected)
    }

    @Test func aWebServerFailureIsNotARefusal() {
        #expect(AppError.internalFailure(reason: "r").isClientRefusal == false)
        #expect(AppError.badRequest(reason: "r").isClientRefusal)
    }
}
