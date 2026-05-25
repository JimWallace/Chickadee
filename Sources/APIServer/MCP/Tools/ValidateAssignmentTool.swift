// APIServer/MCP/Tools/ValidateAssignmentTool.swift
//
// Read tool: watch an assignment's runner validation to completion and report
// the outcome, by assignment public ID. content:read, course-scoped.
//
// Validation is enqueued as a side effect of the suite/notebook edit tools
// (update_suite / update_pattern_family / update_notebook). This tool lets an
// agent then wait for that run to finish — polling pass/fail without a manual
// poll loop — and return the terminal status (or report that it timed out while
// still pending).
//
// When the call arrives over a progress-capable SSE stream (the client accepts
// text/event-stream and supplied a progressToken), the transport streams live
// `notifications/progress` events (queued -> running -> done) before this final
// result; see MCPRoutes. Over plain JSON it simply blocks for the bounded wait
// and returns the outcome. Both paths share watchValidation().

import Core
import Fluent
import Foundation

struct ValidateAssignmentTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// Maximum seconds to wait for a terminal result (clamped 1...120,
        /// default 30). On expiry the tool returns with `timedOut: true`.
        let timeoutSeconds: Int?
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let validationStatus: String
        let timedOut: Bool
    }

    static let name = "validate_assignment"
    static let description =
        "Watch an assignment's runner validation to completion and return the outcome, by assignment "
        + "public ID. Validation is queued automatically when you edit the suite or notebook; this tool "
        + "waits (up to timeoutSeconds, default 30) for it to finish and returns validationStatus "
        + "(passed/failed/no-runner) — or timedOut:true if still pending. Over an SSE connection it also "
        + "streams live queued -> running -> done progress."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "timeoutSeconds": .object([
                "type": .string("integer"),
                "description": .string("Max seconds to wait for a terminal result (1-120, default 30)."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object(["type": .string("string")]),
            "validationStatus": .object(["type": .string("string")]),
            "timedOut": .object(["type": .string("boolean")]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("validationStatus"), .string("timedOut"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.read]

    /// Default / bounds for the bounded wait, shared with the streaming path.
    static let defaultTimeoutSeconds = 30
    static let maxTimeoutSeconds = 120

    static func clampTimeout(_ seconds: Int?) -> Int {
        min(max(seconds ?? defaultTimeoutSeconds, 1), maxTimeoutSeconds)
    }

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        guard let assignment = try await assignmentByPublicID(input.assignmentPublicID, on: context.db)
        else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "No assignment found with public ID \"\(input.assignmentPublicID)\".")
        }
        try await context.authorizeCourseAccess(assignment.courseID, tool: Self.name)

        let timeout = Self.clampTimeout(input.timeoutSeconds)
        let outcome = try await watchValidation(
            on: context.db,
            assignmentPublicID: assignment.publicID,
            pollInterval: .milliseconds(500),
            deadline: ContinuousClock().now.advanced(by: .seconds(timeout)),
            emit: { _, _ in })  // non-streaming: bounded wait, no progress events

        return Output(
            assignmentPublicID: outcome.assignmentPublicID,
            validationStatus: outcome.validationStatus,
            timedOut: outcome.timedOut)
    }
}
