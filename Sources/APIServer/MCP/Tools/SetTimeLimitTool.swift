// APIServer/MCP/Tools/SetTimeLimitTool.swift
//
// Write tool: set an assignment's default per-test execution time limit (the
// number of seconds a single test script may run before it is killed and
// recorded as a timeout), by assignment public ID. content:write,
// course-scoped.
//
// The default lives in the test setup's manifest (`timeLimitSeconds`). A
// per-script override can be set on a hand-written script via author_script /
// update_suite; this tool sets the assignment-wide fallback that every test
// without an override uses. Like set_grading_mode, this is metadata-style: it
// changes a grading-environment knob, not what the tests check, so it does NOT
// re-grade existing submissions, re-run validation, or close the assignment.

import Core
import Fluent
import Foundation

struct SetTimeLimitTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// Default per-test time limit in seconds (integer, 1...600).
        let seconds: Int
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let timeLimitSeconds: Int
    }

    static let name = "set_time_limit"
    static let description =
        "Set an assignment's default per-test execution time limit (seconds) by its public ID — the "
        + "number of seconds one test script may run before it is killed and recorded as a timeout. "
        + "This is the assignment-wide fallback; a hand-written script can override it per-test via "
        + "author_script / update_suite (timeLimitSeconds), and get_suite reports both the default and "
        + "any per-script overrides. seconds must be an integer between 1 and 600. Changing the limit "
        + "is a grading-environment knob, not a change to what the tests check, so it does NOT "
        + "re-grade existing submissions, re-run validation, or change the open/closed state (matching "
        + "set_grading_mode)."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "seconds": .object([
                "type": .string("integer"),
                "minimum": .int(mcpTimeLimitRange.lowerBound),
                "maximum": .int(mcpTimeLimitRange.upperBound),
                "description": .string(
                    "Default per-test time limit in seconds (integer, "
                        + "\(mcpTimeLimitRange.lowerBound)–\(mcpTimeLimitRange.upperBound))."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("seconds")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object(["type": .string("string")]),
            "timeLimitSeconds": .object(["type": .string("integer")]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("timeLimitSeconds")]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let seconds = try validateTimeLimitSeconds(input.seconds, tool: Self.name)
        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, tool: Self.name)
        let effective = try await setManifestTimeLimitSeconds(setup: setup, to: seconds, on: context.db)
        return Output(assignmentPublicID: assignment.publicID, timeLimitSeconds: effective)
    }
}

/// Sets the test setup's default `timeLimitSeconds` to `seconds` when it
/// differs, mutating only that JSON field (so unknown fields the runner doesn't
/// model survive — matching `setManifestGradingMode`). Returns the effective
/// value.
func setManifestTimeLimitSeconds(
    setup: APITestSetup, to seconds: Int, on db: any Database
) async throws -> Int {
    guard var dict = (try? JSONSerialization.jsonObject(with: Data(setup.manifest.utf8))) as? [String: Any]
    else { return seconds }
    if (dict["timeLimitSeconds"] as? Int) != seconds {
        dict["timeLimitSeconds"] = seconds
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        {
            setup.manifest = json
            try await setup.save(on: db)
        }
    }
    return seconds
}
