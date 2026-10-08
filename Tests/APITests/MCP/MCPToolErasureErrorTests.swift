// The tool erasure maps a refusal to the MCP vocabulary for every tool (#1940).
//
// Before it, only the tools that caught `WebAssignmentError` or `AbortError`
// themselves mapped it. `set_grading_mode`, `set_time_limit` and
// `set_minimum_runner_version` did not, so a refusal from their shared
// manifest helpers reached the agent as an opaque -32603.

import Core
import Testing
import Vapor

@testable import APIServer

@Suite struct MCPToolErasureErrorTests {

    /// Throws the error it was built with.
    private struct RefusingTool: ContentTool {
        struct Input: Decodable, Sendable {}
        struct Output: Encodable, Sendable {}

        static let name = "refuse"
        static let description = "Throws the error it was built with."
        static let inputSchema: JSONValue = .object(["type": .string("object")])
        static let requiredScopes: Set<ContentScope> = [.read]

        let failure: any Error

        func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
            throw failure
        }
    }

    private static func invoke(throwing failure: any Error) async throws {
        try await withApp(try await Application.make(.testing)) { app in
            let request = Request(application: app, on: app.eventLoopGroup.any())
            let context = ToolContext(request: request, subject: "tester", grantedScopes: [.read])
            _ = try await RefusingTool(failure: failure).erased().invoke(.object([:]), context)
        }
    }

    @Test func aWebRefusalReachesTheAgentWithItsReason() async throws {
        let refusal = AppError.badRequest(reason: "Unknown grading mode \"fast\".")
        await #expect(throws: MCPToolError.invalidArguments(detail: refusal.reason)) {
            try await Self.invoke(throwing: refusal)
        }
    }

    @Test func aVaporAbortRefusalReachesTheAgentWithItsReason() async throws {
        await #expect(throws: MCPToolError.invalidArguments(detail: "no such section")) {
            try await Self.invoke(throwing: Abort(.badRequest, reason: "no such section"))
        }
    }

    /// A permission refusal is `notAuthorized`, the error the tools throw for
    /// an enrolment refusal, and not `invalidArguments`: no change to the
    /// arguments can make the call succeed.
    @Test func aPermissionRefusalReachesTheAgentAsNotAuthorized() async throws {
        await #expect(throws: MCPToolError.notAuthorized(detail: "not yours")) {
            try await Self.invoke(throwing: Abort(.forbidden, reason: "not yours"))
        }
    }

    /// A server fault is not a refusal: it stays a non-MCP error, so the
    /// dispatcher logs it and the agent sees only an internal error.
    @Test func aServerFaultIsNotMapped() async throws {
        await #expect {
            try await Self.invoke(throwing: Abort(.internalServerError, reason: "disk full"))
        } throws: { error in
            !(error is MCPToolError) && (error as? any AbortError)?.status == .internalServerError
        }
    }

    @Test func anMCPToolErrorPassesThroughUnchanged() async throws {
        let original = MCPToolError.notAuthorized(detail: "not enrolled")
        await #expect(throws: original) {
            try await Self.invoke(throwing: original)
        }
    }

    /// The one remaining `from` maps every `WebAssignmentError`: `forbidden`
    /// is a permission refusal, `internalFailure` is a server failure, and
    /// every other case is a refusal the agent can act on.
    @Test(arguments: [
        AppError.notFound(resource: "Assignment"), .badRequest(reason: "r"),
        .invalidParameter(name: "n", reason: "r"), .noActiveCourse(action: "a"),
        .forbidden(action: "a"), .conflict(reason: "r"), .unprocessable(reason: "r"),
        .validationRequired(reason: "r"), .internalFailure(reason: "r"),
    ])
    func everyWebErrorMapsAsBefore(error: AppError) {
        let mapped = MCPToolError.from(error)
        if case .internalFailure = error {
            #expect(mapped == .executionFailed(detail: error.reason))
        } else if case .forbidden = error {
            #expect(mapped == .notAuthorized(detail: error.reason))
        } else {
            #expect(mapped == .invalidArguments(detail: error.reason))
        }
    }
}
