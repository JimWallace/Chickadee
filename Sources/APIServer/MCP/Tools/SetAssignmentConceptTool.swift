// APIServer/MCP/Tools/SetAssignmentConceptTool.swift
//
// Write tool: tag an assignment with the lab concept whose wardrobe ring full
// marks earn (docs/student-wardrobe.md, "Concept rings" and E6), or clear the
// tag, by assignment public ID. content:write, course-scoped.
//
// The MCP twin of the "Wardrobe ring" select on the edit page
// (`POST /instructor/:id/concept`). The concept is authoring data, not student
// data, and it changes no grade, so the tool neither closes nor regrades.

import Core
import Fluent
import Foundation

struct SetAssignmentConceptTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// An `AssignmentConcept` raw value, or "none" to clear the tag.
        let concept: String
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        /// The stored concept; nil when the tag is cleared.
        let concept: String?
        /// The display name of the ring the concept earns; nil when cleared.
        let ring: String?
    }

    /// The token that clears the tag.
    static let noneToken = "none"

    static let name = "set_assignment_concept"
    static let description =
        "Tag an assignment, by its public ID, with the lab concept whose wardrobe ring a student earns "
        + "when every test passes on it: \(MCPEnumProse<AssignmentConcept>.slashAlternatives). Pass "
        + "\"\(noneToken)\" to clear the tag. The tag is optional, and several assignments may share one "
        + "concept. It changes no grade, so nothing closes or regrades. Choose the concept the assignment "
        + "teaches; do not guess it from the title. Read the current tag from get_assignment."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "concept": .object([
                "type": .string("string"),
                "enum": .array((MCPEnumProse<AssignmentConcept>.tokens + [noneToken]).map { .string($0) }),
                "description": .string(
                    "A concept (\(MCPEnumProse<AssignmentConcept>.slashAlternatives)), or "
                        + "\"\(noneToken)\" to clear the tag."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("concept")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "concept": MCPSchema.nullableString,
            "ring": MCPSchema.nullableString,
        ]),
        "required": .array([.string("assignmentPublicID"), .string("concept"), .string("ring")]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let token = input.concept.trimmingCharacters(in: .whitespacesAndNewlines)
        let concept: AssignmentConcept? =
            token == Self.noneToken
            ? nil : try MCPEnumProse<AssignmentConcept>.parse(token, field: "concept")
        // Instructor-level, matching the web Student Options route.
        let (assignment, _) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, atLeast: .instructor)
        assignment.concept = concept
        try await assignment.save(on: context.db)
        return Output(
            assignmentPublicID: assignment.publicID,
            concept: concept?.rawValue,
            ring: concept?.ring.displayName)
    }
}
