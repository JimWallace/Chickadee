// APIServer/MCP/Tools/AssignmentOrderingTools.swift
//
// reorder_section_items and reorder_assignments — set the instructor-defined
// display order WITHIN a course section, mirroring the web instructor
// dashboard's drag-reorder (POST /instructor/section-items/reorder,
// InstructorDashboardRoutes.reorderSectionItems).
//
// Assignments and ungraded content items share ONE per-section `sort_order`
// sequence (the unified-interleave model), so a reading can sit between two
// labs. `reorder_section_items` is the primary tool: it takes the section's
// full mixed order (assignments + content items) and renumbers both tables.
// `reorder_assignments` is the assignment-only convenience for a section with
// no content items; `reorder_content_items` (CourseContentItemTools) is its
// content-only sibling. reorder_course_sections orders the section groups
// themselves; set_assignment_course_section moves an assignment between groups.
//
// Organizational metadata only: these write `sort_order` and never re-run
// validation, change a manifest, or touch the open/closed state.

import Core
import Fluent
import Foundation

// MARK: - reorder_section_items

struct ReorderSectionItemsTool: ContentTool {
    /// The two kinds of item a course section holds.
    typealias ItemType = SectionItemKind

    struct ItemRef: Decodable, Sendable {
        /// An `ItemType` raw value.
        let type: String
        /// Assignment public ID (type "assignment") or content-item id (type "content").
        let id: String
    }

    struct Input: Decodable, Sendable {
        let courseCode: String
        /// One section's items in the new display order — a mix of assignments
        /// (from list_assignments) and content items (from list_content_items),
        /// every item of one section. Renumbered 1..n together.
        let orderedItems: [ItemRef]
    }

    struct Output: Encodable, Sendable {
        struct Item: Encodable, Sendable {
            let type: String
            let id: String
            let title: String
            let sortOrder: Int
        }
        let courseCode: String
        /// The key and term of the course acted on; see `MCPSchema.courseKeyOutput`.
        let courseKey: String
        let courseTerm: String?
        let items: [Item]
    }

    static let name = "reorder_section_items"
    static let description =
        "Set the interleaved display order of a course section's items — assignments AND ungraded "
        + "content items share ONE per-section order, so a reading can sit between two labs. "
        + "orderedItems lists EVERY item of one section, or every ungrouped item "
        + "({type:\"assignment\", id:<public ID>} or {type:\"content\", id:<content-item id>}), in the "
        + "desired order; they are renumbered 1..n together. A partial list, a duplicate id or an unknown "
        + "type is refused. This is the primary ordering tool; use "
        + "reorder_assignments / reorder_content_items only for a single-type section, and "
        + "set_assignment_course_section / update_content_item to move an item between sections first. "
        + "Organizational metadata only: it does not re-run validation or change the open/closed state."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.courseCode,
            "orderedItems": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object([
                            "type": .string("string"),
                            "enum": MCPEnumProse<ItemType>.jsonEnum,
                            "description": .string("\(MCPEnumProse<ItemType>.quotedOrList)."),
                        ]),
                        "id": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Assignment public ID or content-item id, matching type."),
                        ]),
                    ]),
                    "required": .array([.string("type"), .string("id")]),
                ]),
                "description": .string("The section's items in the desired interleaved order."),
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("orderedItems")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.string,
            "courseKey": MCPSchema.courseKeyOutput,
            "courseTerm": MCPSchema.courseTermOutput,
            "items": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": MCPSchema.string,
                        "id": MCPSchema.string,
                        "title": MCPSchema.string,
                        "sortOrder": MCPSchema.integer,
                    ]),
                    "required": .array([
                        .string("type"), .string("id"), .string("title"), .string("sortOrder"),
                    ]),
                ]),
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("courseKey"), .string("items")]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    // Every reorder kind floors at SortOrderRenumbering.roleFloor (.ta), web
    // and MCP (#2713).
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let course = try await resolveCourseForWrite(
            code: input.courseCode, context: context, atLeast: SortOrderRenumbering.roleFloor)
        let renumbered = try await renumberSectionItemsForMCP(
            field: "orderedItems", course: course, context: context
        ) { () throws(ReorderError) in
            try input.orderedItems.map { ref throws(ReorderError) in
                try SortOrderItem.parse(type: ref.type, id: ref.id)
            }
        }
        let ordered = try renumbered.enumerated().map { index, row in
            switch row {
            case .assignment(let assignment):
                Output.Item(
                    type: SectionItemKind.assignment.rawValue, id: assignment.publicID,
                    title: assignment.title, sortOrder: index + 1)
            case .content(let item):
                Output.Item(
                    type: SectionItemKind.content.rawValue, id: try item.requireID().uuidString,
                    title: item.title, sortOrder: index + 1)
            }
        }
        return Output(
            courseCode: course.code, courseKey: course.urlKey, courseTerm: course.term?.displayName,
            items: ordered)
    }
}

// MARK: - reorder_assignments

struct ReorderAssignmentsTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
        /// Every assignment public ID of one section, in the new order,
        /// renumbered 1..n.
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
        /// The key and term of the course acted on; see `MCPSchema.courseKeyOutput`.
        let courseKey: String
        let courseTerm: String?
        let assignments: [Assignment]
    }

    static let name = "reorder_assignments"
    static let description =
        "Set the display order of assignments WITHIN a course section, by course code. "
        + "orderedAssignmentPublicIDs lists EVERY assignment of one section, or every ungrouped "
        + "assignment (from list_assignments); they are renumbered 1..n. A partial list is refused. "
        + "Assignments and content items share one per-section order, so a section that ALSO holds "
        + "content items is refused here: use reorder_section_items (it interleaves both). Move an assignment between sections with "
        + "set_assignment_course_section, and order the section groups with reorder_course_sections. "
        + "Organizational metadata only: it does not re-run validation or change the open/closed state."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.courseCode,
            "orderedAssignmentPublicIDs": .object([
                "type": .string("array"),
                "items": MCPSchema.string,
                "description": .string(
                    "The section's assignment public IDs in the desired order (one section)."),
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("orderedAssignmentPublicIDs")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.string,
            "courseKey": MCPSchema.courseKeyOutput,
            "courseTerm": MCPSchema.courseTermOutput,
            "assignments": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "publicID": MCPSchema.string,
                        "title": MCPSchema.string,
                        "sortOrder": MCPSchema.integer,
                        "sectionID": MCPSchema.string,
                    ]),
                    "required": .array([
                        .string("publicID"), .string("title"), .string("sortOrder"),
                        .string("sectionID"),
                    ]),
                ]),
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("courseKey"), .string("assignments")]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let course = try await resolveCourseForWrite(
            code: input.courseCode, context: context, atLeast: SortOrderRenumbering.roleFloor)
        let renumbered = try await renumberSectionItemsForMCP(
            field: "orderedAssignmentPublicIDs", course: course, context: context
        ) { () throws(ReorderError) in
            try input.orderedAssignmentPublicIDs.map(SortOrderItem.parseAssignment)
        }
        let ordered = renumbered.enumerated().compactMap { index, row -> Output.Assignment? in
            guard case .assignment(let assignment) = row else { return nil }
            return Output.Assignment(
                publicID: assignment.publicID,
                title: assignment.title,
                sortOrder: index + 1,
                sectionID: assignment.sectionID?.uuidString ?? "")
        }
        return Output(
            courseCode: course.code, courseKey: course.urlKey, courseTerm: course.term?.displayName,
            assignments: ordered)
    }
}

// MARK: - Shared

/// Parses a section-item reorder and runs it through `SortOrderRenumbering`
/// for `course`, mapping a `ReorderError` to `MCPToolError` on `field`. The
/// caller has authorized the course at `SortOrderRenumbering.roleFloor`.
func renumberSectionItemsForMCP(
    field: String, course: APICourse, context: ToolContext,
    _ parse: () throws(ReorderError) -> [SortOrderItem]
) async throws -> [RenumberedSectionItem] {
    do {
        let items = try parse()
        return try await SortOrderRenumbering.renumberSectionItems(
            items, inCourse: try course.requireID(), on: context.db)
    } catch let error as ReorderError {
        var detail = "\(field): \(error.reason)"
        if case .incompleteSection = error {
            detail += " A section that holds both assignments and content items needs reorder_section_items."
        }
        throw MCPToolError.invalidArguments(detail: detail)
    }
}
