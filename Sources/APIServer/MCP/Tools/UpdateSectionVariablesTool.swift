// APIServer/MCP/Tools/UpdateSectionVariablesTool.swift
//
// Write tool: replace one test-suite section's personalization inputs — the
// section-scoped literal `variables` and per-student `expressions` — by
// assignment public ID + section id.  content:write, course-scoped.  Mirrors
// `POST /instructor/:assignmentID/suite-sections/:sectionID/variables` and drives
// the same `SectionInputsService.apply` path the web editor uses, so the same
// validation runs (identifier-shape names, the reserved `seed` name, uniqueness
// within the section, no clash with globals or any other section, and a
// save-time eval against the acting account's own seed).
//
// Both lists are REPLACED wholesale — send the complete desired set.  Section
// ids come from get_suite.  This only touches the section's variables/
// expressions; it does not re-render generated tests.

import Core
import Fluent
import Foundation

struct UpdateSectionVariablesTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        let sectionID: String
        let variables: [FamilyVariable]
        let expressions: [PersonalizationExpression]?
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let sectionID: String
        let variables: [FamilyVariable]
        let expressions: [PersonalizationExpression]
    }

    static let name = "update_section_variables"
    static let description =
        "Replace one test-suite section's personalization inputs, by assignment public ID + section "
        + "id (from get_suite). Provide the full desired `variables` (literal name + JSON value) and "
        + "`expressions` (name + Python source evaluated per-student against `seed`); both lists are "
        + "replaced wholesale, not merged. Names must be valid Python identifiers, unique within the "
        + "section, and must not clash with global inputs or any other section; `seed` is reserved. "
        + "Each expression is eval-checked against your own seed before saving."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "sectionID": .object([
                "type": .string("string"),
                "description": .string("The section's id (from get_suite)."),
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
        "required": .array([
            .string("assignmentPublicID"), .string("sectionID"), .string("variables"),
        ]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object(["type": .string("string")]),
            "sectionID": .object(["type": .string("string")]),
            "variables": .object(["type": .string("array")]),
            "expressions": .object(["type": .string("array")]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("sectionID"), .string("variables"),
            .string("expressions"),
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

        let actingUser = try await context.requireEligibleSubject(tool: Self.name)

        do {
            try await SectionInputsService.apply(
                setup: setup,
                sectionID: input.sectionID,
                inputs: .init(variables: input.variables, expressions: input.expressions ?? []),
                seed: .init(
                    actingUserID: actingUser.id,
                    assignmentID: assignment.id,
                    testSetupID: assignment.testSetupID,
                    testSetupsDirectory: context.request.application.testSetupsDirectory),
                on: context.db)
        } catch let error as WebAssignmentError {
            throw MCPToolError.from(error, tool: Self.name)
        }

        let reloaded = try SectionInputsService.current(setup: setup, sectionID: input.sectionID)
        return Output(
            assignmentPublicID: assignment.publicID,
            sectionID: input.sectionID,
            variables: reloaded?.variables ?? input.variables,
            expressions: reloaded?.expressions ?? (input.expressions ?? []))
    }
}
