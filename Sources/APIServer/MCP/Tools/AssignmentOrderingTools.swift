// APIServer/MCP/Tools/AssignmentOrderingTools.swift
//
// reorder_assignments — sets the instructor-defined display order of a course's
// assignments, mirroring the web instructor dashboard's drag-reorder
// (`POST /instructor/reorder`, InstructorDashboardRoutes.reorderAssignments).
// Assignment order is a single course-global integer (`APIAssignment.sortOrder`,
// lower first); the dashboard buckets the globally-ordered rows by their course
// section for display.  This is the assignment-level counterpart to
// reorder_course_sections (which orders the section groups themselves) and, like
// it, takes a full permutation so every assignment ends with an explicit
// sortOrder (no mix of numbered/unnumbered rows to sort surprisingly).
//
// Organizational metadata only: it writes `sort_order` and never re-runs
// validation, changes a manifest, or touches the open/closed state.

import Core
import Fluent
import Foundation

// MARK: - reorder_assignments

struct ReorderAssignmentsTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
        /// The course's assignment public IDs in the new display order — must be
        /// a permutation of the course's current assignments, not a subset.
        let orderedAssignmentPublicIDs: [String]
    }

    struct Output: Encodable, Sendable {
        struct Assignment: Encodable, Sendable {
            let publicID: String
            let title: String
            let sortOrder: Int
            /// The course section the assignment belongs to; "" when ungrouped.
            let sectionID: String
        }
        let courseCode: String
        let assignments: [Assignment]
    }

    static let name = "reorder_assignments"
    static let description =
        "Set the instructor-defined display order of a course's assignments, by course code. "
        + "orderedAssignmentPublicIDs must list exactly the course's current assignment public IDs "
        + "(from list_assignments) in the desired order — a permutation, not a subset. Assignment "
        + "order is course-global (lower first); the dashboard still groups the ordered assignments "
        + "by their course section for display, so this orders assignments WITHIN each section as "
        + "well as overall — it does not interleave sections (use reorder_course_sections to order "
        + "the groups, and set_assignment_course_section to move an assignment between groups). "
        + "Organizational metadata only: it does not re-run validation or change the open/closed state."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": .object([
                "type": .string("string"),
                "description": .string("The course code, e.g. \"CS136\"."),
            ]),
            "orderedAssignmentPublicIDs": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string(
                    "The course's assignment public IDs in the new order (a permutation of all of them)."),
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("orderedAssignmentPublicIDs")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": .object(["type": .string("string")]),
            "assignments": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "publicID": .object(["type": .string("string")]),
                        "title": .object(["type": .string("string")]),
                        "sortOrder": .object(["type": .string("integer")]),
                        "sectionID": .object(["type": .string("string")]),
                    ]),
                    "required": .array([
                        .string("publicID"), .string("title"), .string("sortOrder"),
                        .string("sectionID"),
                    ]),
                ]),
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("assignments")]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let courseID = try await resolveCourseIDForWrite(code: input.courseCode, tool: Self.name, context: context)

        let ids = input.orderedAssignmentPublicIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard ids.allSatisfy(isValidAssignmentPublicID(_:)) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "orderedAssignmentPublicIDs contains an invalid assignment public ID.")
        }
        guard Set(ids).count == ids.count else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "orderedAssignmentPublicIDs contains a duplicate assignment public ID.")
        }

        let assignments = try await APIAssignment.query(on: context.db)
            .filter(\.$courseID == courseID)
            .all()
        let existing = Set(assignments.map(\.publicID))
        guard existing == Set(ids) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "orderedAssignmentPublicIDs must list exactly the course's current assignment "
                    + "public IDs (a permutation of all \(existing.count)).")
        }

        let byID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.publicID, $0) })
        var ordered: [Output.Assignment] = []
        for (index, publicID) in ids.enumerated() {
            guard let assignment = byID[publicID] else { continue }
            assignment.sortOrder = index + 1
            try await assignment.save(on: context.db)
            ordered.append(
                Output.Assignment(
                    publicID: publicID,
                    title: assignment.title,
                    sortOrder: index + 1,
                    sectionID: assignment.sectionID?.uuidString ?? ""))
        }
        return Output(courseCode: input.courseCode, assignments: ordered)
    }
}
