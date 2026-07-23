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
    struct ItemRef: Decodable, Sendable {
        /// "assignment" or "content".
        let type: String
        /// Assignment public ID (type "assignment") or content-item id (type "content").
        let id: String
    }

    struct Input: Decodable, Sendable {
        let courseCode: String
        /// One section's items in the new display order — a mix of assignments
        /// (from list_assignments) and content items (from list_content_items),
        /// normally all in the same section. Renumbered 1..n together.
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
        let items: [Item]
    }

    static let name = "reorder_section_items"
    static let description =
        "Set the interleaved display order of a course section's items — assignments AND ungraded "
        + "content items share ONE per-section order, so a reading can sit between two labs. "
        + "orderedItems lists the section's items ({type:\"assignment\", id:<public ID>} or "
        + "{type:\"content\", id:<content-item id>}) in the desired order, normally all in one "
        + "section; they are renumbered 1..n together. This is the primary ordering tool; use "
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
                            "enum": .array([.string("assignment"), .string("content")]),
                            "description": .string("\"assignment\" or \"content\"."),
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
        "required": .array([.string("courseCode"), .string("items")]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    // Reordering the display list is content organization, TA+ (matching
    // reorder_content_items and the web POST /instructor/section-items/reorder).
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let courseID = try await resolveCourseIDForWrite(
            code: input.courseCode, tool: Self.name, context: context, atLeast: .ta)

        let assignmentIDs = input.orderedItems.filter { $0.type == "assignment" }.map(\.id)
        let contentRaw = input.orderedItems.filter { $0.type == "content" }.map(\.id)
        guard input.orderedItems.allSatisfy({ $0.type == "assignment" || $0.type == "content" }) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "each item type must be \"assignment\" or \"content\".")
        }
        guard assignmentIDs.allSatisfy(isValidAssignmentPublicID(_:)) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "orderedItems contains an invalid assignment public ID.")
        }
        let contentUUIDs = contentRaw.compactMap {
            UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard contentUUIDs.count == contentRaw.count else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "orderedItems contains an invalid content-item id.")
        }
        guard Set(assignmentIDs).count == assignmentIDs.count, Set(contentUUIDs).count == contentUUIDs.count
        else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "orderedItems contains a duplicate id.")
        }

        // Scope both fetches to this course so the payload can't renumber another
        // course's items.
        let assignments =
            assignmentIDs.isEmpty
            ? []
            : try await APIAssignment.query(on: context.db)
                .filter(\.$courseID == courseID).filter(\.$publicID ~~ assignmentIDs).all()
        let contentItems =
            contentUUIDs.isEmpty
            ? []
            : try await APICourseContentItem.query(on: context.db)
                .filter(\.$courseID == courseID).filter(\.$id ~~ contentUUIDs).all()
        guard assignments.count == assignmentIDs.count, contentItems.count == contentUUIDs.count else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "orderedItems must all be assignments or content items in course \(input.courseCode).")
        }
        let assignmentByPublicID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.publicID, $0) })
        let contentByID = Dictionary(
            uniqueKeysWithValues: contentItems.compactMap { c in c.id.map { ($0, c) } })

        var ordered: [Output.Item] = []
        for (index, ref) in input.orderedItems.enumerated() {
            let order = index + 1
            if ref.type == "assignment", let assignment = assignmentByPublicID[ref.id] {
                assignment.sortOrder = order
                try await assignment.save(on: context.db)
                ordered.append(
                    Output.Item(type: "assignment", id: ref.id, title: assignment.title, sortOrder: order))
            } else if let uuid = UUID(uuidString: ref.id), let item = contentByID[uuid] {
                item.sortOrder = order
                try await item.save(on: context.db)
                ordered.append(
                    Output.Item(type: "content", id: ref.id, title: item.title, sortOrder: order))
            }
        }
        return Output(courseCode: input.courseCode, items: ordered)
    }
}

// MARK: - reorder_assignments

struct ReorderAssignmentsTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
        /// One section's assignment public IDs in the new order — normally all in
        /// the same section, renumbered 1..n among themselves.
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
        "Set the display order of assignments WITHIN a course section, by course code. "
        + "orderedAssignmentPublicIDs lists the assignments to order (from list_assignments), normally "
        + "all in the same section; they are renumbered 1..n among themselves. Assignments and content "
        + "items share one per-section order, so for a section that ALSO holds content items use "
        + "reorder_section_items instead (it interleaves both). Move an assignment between sections with "
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
                    "The section's assignment public IDs in the desired order (normally one section)."),
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("orderedAssignmentPublicIDs")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.string,
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
        "required": .array([.string("courseCode"), .string("assignments")]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let courseID = try await resolveCourseIDForWrite(
            code: input.courseCode, tool: Self.name, context: context, atLeast: .ta)

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
        guard !ids.isEmpty else {
            return Output(courseCode: input.courseCode, assignments: [])
        }

        // Scope to this course so a reorder can't renumber another course's rows.
        let assignments = try await APIAssignment.query(on: context.db)
            .filter(\.$courseID == courseID)
            .filter(\.$publicID ~~ ids)
            .all()
        guard assignments.count == ids.count else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "orderedAssignmentPublicIDs must all be assignments in course \(input.courseCode).")
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
