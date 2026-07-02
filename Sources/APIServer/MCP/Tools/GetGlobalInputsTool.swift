// APIServer/MCP/Tools/GetGlobalInputsTool.swift
//
// Read tool: returns an assignment's global inputs (personalization) by public
// ID — the literal `variables` (name + JSON value) and per-student
// `expressions` (name + Python source).  content:read, course-scoped.  Mirrors
// `GET /instructor/:assignmentID/global-variables`.

import Core
import Fluent
import Foundation

struct GetGlobalInputsTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        /// Literal values inlined into generated/raw tests and substituted into
        /// the starter notebook at student first-open.
        let variables: [FamilyVariable]
        /// Python expressions evaluated per-student at notebook first-open
        /// (`seed` + every static variable in scope).
        let expressions: [PersonalizationExpression]
    }

    static let name = "get_global_inputs"
    static let description =
        "Get an assignment's global inputs (personalization) by public ID: the literal `variables` "
        + "(each a name + JSON value) and the per-student `expressions` (each a name + Python source "
        + "evaluated against the student's seed). Read-only — use this to inspect personalization "
        + "before editing it with update_global_inputs."
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
            "variables": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": MCPSchema.string,
                        "value": .object([:]),
                    ]),
                    "required": .array([.string("name"), .string("value")]),
                ]),
            ]),
            "expressions": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": MCPSchema.string,
                        "expression": MCPSchema.string,
                    ]),
                    "required": .array([.string("name"), .string("expression")]),
                ]),
            ]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("variables"), .string("expressions"),
        ]),
    ])
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let (assignment, setup) = try await context.authorizedAssignmentAndSetup(
            publicID: input.assignmentPublicID, tool: Self.name)

        let result = try GlobalInputsService.current(setup: setup)
        return Output(
            assignmentPublicID: assignment.publicID,
            variables: result.variables,
            expressions: result.expressions)
    }
}
