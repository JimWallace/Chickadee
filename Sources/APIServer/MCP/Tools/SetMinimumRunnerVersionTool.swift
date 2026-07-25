// APIServer/MCP/Tools/SetMinimumRunnerVersionTool.swift
//
// Write tool: set (or clear) an assignment's minimum native-runner version
// gate, by assignment public ID. content:write, course-scoped.
//
// The gate lives in the test setup's manifest (`minimumRunnerVersion`). When
// set, the server only hands a submission for this assignment to a native
// runner whose advertised version is >= the gate; otherwise the job waits in
// the queue until a new-enough runner polls. Use it for a suite that depends on
// behaviour only present in a newer runner build. Like set_time_limit and
// set_grading_mode this is a grading-environment knob, not a change to what the
// tests check, so it does NOT re-grade existing submissions, re-run validation,
// or close the assignment. It gates only the native worker path — browser
// grading runs the server's own vended bundle and has no runner version.
//
// Setting the gate can stall grading fleet-wide until a new-enough runner is
// deployed, so it is an instructor-level operational knob (matching
// set_grading_mode), not TA-level content authoring.

import Core
import Fluent
import Foundation

struct SetMinimumRunnerVersionTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// Minimum runner version as a semver string (e.g. "0.5.0"). Null or an
        /// empty string CLEARS the gate.
        let minimumRunnerVersion: String?
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        /// The gate after the edit, or null when the assignment is ungated.
        let minimumRunnerVersion: String?
    }

    static let name = "set_minimum_runner_version"
    static let description =
        "Set (or clear) an assignment's minimum native-runner version gate by its public ID. When "
        + "set, a submission is only graded by a runner whose version is >= this value; otherwise it "
        + "waits in the queue until a new-enough runner is available. Use it for a suite that relies "
        + "on behaviour only present in a newer runner build. minimumRunnerVersion is a semver string "
        + "like \"0.5.0\"; pass null or an empty string to clear the gate. Changing it is a "
        + "grading-environment knob, not a change to what the tests check, so it does NOT re-grade "
        + "existing submissions, re-run validation, or change the open/closed state (matching "
        + "set_time_limit and set_grading_mode). It gates only the native worker path — browser-graded "
        + "assignments have no runner version and are never gated. get_suite and get_assignment report "
        + "the current value."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "minimumRunnerVersion": .object([
                "type": .string("string"),
                "description": .string(
                    "Minimum runner version as a semver string (e.g. \"0.5.0\"). Null or an empty "
                        + "string clears the gate."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "minimumRunnerVersion": MCPSchema.string,
        ]),
        "required": .array([.string("assignmentPublicID")]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        // Validate before the auth-load so a malformed version fails fast. A
        // blank/nil value is not an error — it means "clear the gate".
        let requested = input.minimumRunnerVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requested, !requested.isEmpty, !RunnerVersionGate.isParseable(requested) {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "minimumRunnerVersion must be a version like \"0.5.0\" (got \"\(requested)\"); "
                    + "pass null or an empty string to clear the gate.")
        }
        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, tool: Self.name, atLeast: .instructor)
        let effective = try await setManifestMinimumRunnerVersion(
            setup: setup, to: requested, on: context.db)
        return Output(assignmentPublicID: assignment.publicID, minimumRunnerVersion: effective)
    }
}
