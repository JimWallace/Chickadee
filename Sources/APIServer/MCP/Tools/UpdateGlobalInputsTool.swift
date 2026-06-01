// APIServer/MCP/Tools/UpdateGlobalInputsTool.swift
//
// Write tool: replace an assignment's global inputs (personalization) by public
// ID — the literal `variables` and the per-student `expressions`.  content:write,
// course-scoped.  Mirrors `PUT /instructor/:assignmentID/global-variables` and
// drives the same `GlobalInputsService.apply` path the web editor uses, so the
// same validation runs (identifier-shape names, the reserved `seed` name,
// cross-list/section uniqueness, the starter-notebook `{{undeclared}}` scan, and
// a save-time eval of every expression against the acting account's own seed).
//
// Both lists are REPLACED wholesale — send the complete desired set, not a
// delta.  Saving re-renders generated/raw tests so inlined literal values stay
// current.

import Core
import Fluent
import Foundation

struct UpdateGlobalInputsTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// Replacement literal values (name + JSON value).  Required; send `[]`
        /// to clear all literals.
        let variables: [FamilyVariable]
        /// Replacement per-student expressions (name + Python source).  Optional;
        /// omitted leaves the request treating expressions as `[]` (cleared).
        let expressions: [PersonalizationExpression]?
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let variables: [FamilyVariable]
        let expressions: [PersonalizationExpression]
        /// Non-blocking warnings surfaced by the save (currently always empty).
        let warnings: [String]
    }

    static let name = "update_global_inputs"
    static let description =
        "Replace an assignment's global inputs (personalization), by its public ID. Provide the full "
        + "desired `variables` (literal name + JSON value) and `expressions` (name + Python source "
        + "evaluated per-student against `seed`); both lists are replaced wholesale, not merged. "
        + "Names must be valid Python identifiers, unique across both lists and any section variable, "
        + "and `seed` is reserved. Every starter-notebook `{{placeholder}}` must match a declared name. "
        + "Each expression is eval-checked against your own seed before saving, so typos are caught here."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "variables": .object([
                "type": .string("array"),
                "description": .string("Replacement literal values; send [] to clear."),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Valid Python identifier; not \"seed\"."),
                        ]),
                        "value": .object([
                            "description": .string("Any JSON-expressible Python literal (scalar, list, dict).")
                        ]),
                    ]),
                    "required": .array([.string("name"), .string("value")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
            "expressions": .object([
                "type": .string("array"),
                "description": .string("Replacement per-student expressions; omit or send [] to clear."),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Valid Python identifier; not \"seed\"."),
                        ]),
                        "expression": .object([
                            "type": .string("string"),
                            "description": .string("Python expression; `seed` and every variable are in scope."),
                        ]),
                    ]),
                    "required": .array([.string("name"), .string("expression")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("variables")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object(["type": .string("string")]),
            "variables": .object(["type": .string("array")]),
            "expressions": .object(["type": .string("array")]),
            "warnings": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
            ]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("variables"), .string("expressions"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        guard let assignment = try await assignmentByPublicID(input.assignmentPublicID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "No assignment found with public ID \"\(input.assignmentPublicID)\".")
        }
        try await context.authorizeCourseAccess(assignment.courseID, tool: Self.name)
        guard let setup = try await APITestSetup.find(assignment.testSetupID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "The assignment's test setup could not be found.")
        }

        // The save-time expression eval runs against the acting account's own
        // seed — same as the instructor's seed on the web path.
        let actingUser = try await context.requireEligibleSubject(tool: Self.name)

        let result: GlobalInputsService.Result
        do {
            result = try await GlobalInputsService.apply(
                setup: setup,
                assignment: assignment,
                actingUserID: actingUser.id,
                inputs: .init(variables: input.variables, expressions: input.expressions ?? []),
                testSetupsDirectory: context.request.application.testSetupsDirectory,
                on: context.db)
        } catch let error as WebAssignmentError {
            throw MCPToolError.from(error, tool: Self.name)
        }

        return Output(
            assignmentPublicID: assignment.publicID,
            variables: result.variables,
            expressions: result.expressions,
            warnings: result.warnings)
    }
}
