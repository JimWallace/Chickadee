// APIServer/MCP/Tools/GetValidationResultTool.swift
//
// Read tool: returns the per-test outcomes of an assignment's latest VALIDATION
// run (the instructor's reference solution graded against the current suite), by
// assignment public ID. content:read, course-scoped.
//
// This closes the diagnosis loop that `validate_assignment` leaves open: that
// tool reports only a single word (passed/failed/no-runner), so a failing suite
// can't be diagnosed without a human copying the per-test grid out of the web
// UI. Here the agent sees which check failed and why (shortResult / longResult),
// so it can fix the suite or solution on the instructor's behalf.
//
// Hard guardrails (see docs/mcp-validation-access.md):
//   * Validation submissions ONLY. The submission is resolved from the
//     assignment (linked validation submission, else the most recent
//     `kind == .validation` for the setup) and filtered to `.validation`; a
//     student submission is never reachable, and no raw submission id is
//     accepted.
//   * Course-scoped authorization, identical to every other content tool.
//   * The DTO carries no student identity, grade, or roster — only the
//     instructor's own reference-solution run. `submissionID` / `userID` are
//     dropped. All tiers are returned (the agent needs secret-tier outcomes to
//     debug the suite); this is the same instructor-authored trust tier already
//     exposed by get_solution / get_suite.

import Core
import Fluent
import Foundation

struct GetValidationResultTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
    }

    struct OutcomeDTO: Encodable, Sendable {
        let testName: String
        let tier: String
        let status: String
        let points: Int
        let shortResult: String
        let longResult: String?
    }

    struct Counts: Encodable, Sendable {
        let total: Int
        let pass: Int
        let fail: Int
        let error: Int
        let timeout: Int
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        /// The assignment's current `validationStatus`: passed | failed |
        /// no-runner | pending | none. Mirrors validate_assignment.
        let validationStatus: String
        /// When the run that produced `outcomes` completed (ISO 8601); nil when
        /// no validation result exists yet.
        let ranAt: String?
        /// Collection-level build status: passed | failed | skipped (nil when no
        /// result yet). A failed build means `outcomes` is empty.
        let buildStatus: String?
        let compilerOutput: String?
        let warnings: [String]
        let outcomes: [OutcomeDTO]
        let counts: Counts?
    }

    static let name = "get_validation_result"
    static let description =
        "Get the per-test outcomes of an assignment's latest VALIDATION run (the instructor's reference "
        + "solution graded against the current suite), by assignment public ID. Unlike validate_assignment "
        + "(which returns only passed/failed/no-runner), this returns each check's status and its "
        + "shortResult/longResult so you can see WHICH test failed and WHY, then fix the suite or solution. "
        + "Validation runs only — it resolves the instructor's own reference-solution run from the "
        + "assignment and never accepts or returns a student submission, identity, or grade. All tiers "
        + "(public/release/secret/student) are included so secret-tier failures are visible. A pending or "
        + "missing run returns the current validationStatus with empty outcomes."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID
        ]),
        "required": .array([.string("assignmentPublicID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "validationStatus": MCPSchema.string,
            "ranAt": .object(["type": .array([.string("string"), .string("null")])]),
            "buildStatus": .object(["type": .array([.string("string"), .string("null")])]),
            "compilerOutput": .object(["type": .array([.string("string"), .string("null")])]),
            "warnings": .object([
                "type": .string("array"), "items": MCPSchema.string,
            ]),
            "outcomes": .object(["type": .string("array")]),
            "counts": .object(["type": .array([.string("object"), .string("null")])]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("validationStatus"), .string("outcomes"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let assignment = try await context.authorizedAssignment(
            publicID: input.assignmentPublicID, tool: Self.name)
        let status = assignment.validationStatus ?? "none"

        guard
            let submission = try await MCPStudentDataBoundary.validationSubmission(
                for: assignment, on: context.db)
        else {
            return Self.empty(assignmentPublicID: assignment.publicID, validationStatus: status)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard
            let result = try await MCPStudentDataBoundary.latestResult(
                forSubmissionID: submission.requireID(), on: context.db),
            let data = result.collectionJSON.data(using: .utf8),
            let collection = try? decoder.decode(TestOutcomeCollection.self, from: data)
        else {
            return Self.empty(assignmentPublicID: assignment.publicID, validationStatus: status)
        }

        let outcomes = collection.outcomes.map {
            OutcomeDTO(
                testName: $0.testName,
                tier: $0.tier.rawValue,
                status: $0.status.rawValue,
                points: $0.points,
                shortResult: $0.shortResult,
                longResult: $0.longResult)
        }

        return Output(
            assignmentPublicID: assignment.publicID,
            validationStatus: status,
            ranAt: ISO8601DateFormatter().string(from: collection.timestamp),
            buildStatus: collection.buildStatus.rawValue,
            compilerOutput: collection.compilerOutput,
            warnings: collection.warnings,
            outcomes: outcomes,
            counts: Counts(
                total: collection.totalTests,
                pass: collection.passCount,
                fail: collection.failCount,
                error: collection.errorCount,
                timeout: collection.timeoutCount))
    }

    /// The pending / no-result-yet response: the current status with no outcomes
    /// (mirrors validate_assignment's pending state).
    private static func empty(assignmentPublicID: String, validationStatus: String) -> Output {
        Output(
            assignmentPublicID: assignmentPublicID,
            validationStatus: validationStatus,
            ranAt: nil,
            buildStatus: nil,
            compilerOutput: nil,
            warnings: [],
            outcomes: [],
            counts: nil)
    }
}
