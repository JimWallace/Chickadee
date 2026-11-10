// APIServer/MCP/Tools/AttachContentItemTool.swift
//
// attach_content_item: the MCP door to the material edit form's "Show on"
// select. An attached content item shows as extra buttons on its assignment's
// row rather than as a row of its own, and takes the assignment's section. The
// write is `CourseContentService.attach`, which the web handler shares, so the
// rules (no heading, no assignment from another course, detach lands the item
// at the end of the assignment's current section) are the same on both doors.
//
// An attached item reaches students only when its assignment does
// (`ContentItemVisibility`), so the output reports whether a student with no
// extension sees the item before and after the change: an attach can hide
// material that was visible.

import Core
import Fluent
import Foundation
import Vapor

struct AttachContentItemTool: ContentTool {
    struct Input: Decodable, Sendable {
        let contentItemID: String
        /// The assignment's public ID; "" detaches.
        let assignmentPublicID: String
    }

    struct Output: Encodable, Sendable {
        let contentItem: ContentItemDTO
        /// Whether a student without an extension saw the item before the call.
        let wasVisibleToStudents: Bool
        /// Whether a student without an extension sees the item now.
        let isVisibleToStudents: Bool
    }

    static let name = "attach_content_item"
    static let description =
        "Attach an ungraded content item (from list_content_items) to an assignment in the same "
        + "course, by the assignment's public ID, or detach it with assignmentPublicID \"\". An attached item shows as extra buttons on that assignment's row instead of as "
        + "a row of its own, takes the assignment's section, and is left out of "
        + "reorder_section_items; a detached item returns as a row at the end of the assignment's "
        + "current section. A heading cannot attach. Students see an attached item only when they "
        + "can complete its assignment (an extension included) or after the assignment closes at its "
        + "deadline, so an attach can hide material that was visible: the output reports "
        + "wasVisibleToStudents and isVisibleToStudents for a student with no extension. Attaching "
        + "an item to the assignment it is already on changes nothing. Ungraded material only: no "
        + "re-validation, no re-grade, no close."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "contentItemID": .object([
                "type": .string("string"),
                "description": .string("Content-item id (from list_content_items)."),
            ]),
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string(
                    "The 6-character public ID of an assignment in the item's course, or \"\" to "
                        + "detach the item and give it a row of its own."),
            ]),
        ]),
        "required": .array([.string("contentItemID"), .string("assignmentPublicID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "contentItem": .object([
                "type": .string("object"),
                "description": .string(
                    "The item after the change, in the list_content_items shape, with "
                        + "attachedAssignmentPublicID absent when detached."),
            ]),
            "wasVisibleToStudents": MCPSchema.boolean,
            "isVisibleToStudents": MCPSchema.boolean,
        ]),
        "required": .array([
            .string("contentItem"), .string("wasVisibleToStudents"), .string("isVisibleToStudents"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let item = try await resolveContentItemForWrite(
            contentItemID: input.contentItemID, context: context,
            atLeast: CourseRoleFloor.manageContentItems)
        let before = try await Self.attachedAssignment(of: item, on: context.db)
        let wasVisible = ContentItemVisibility.isVisibleToStudents(item, attachedTo: before)

        do {
            let targetID = try await CourseContentService.attachTarget(
                publicID: input.assignmentPublicID, for: item, on: context.db)
            try await CourseContentService.attach(item, toAssignment: targetID, on: context.db)
        } catch let error as CourseContentError {
            throw mcpToolError(error)
        }

        let after = try await Self.attachedAssignment(of: item, on: context.db)
        var dto = contentItemDTO(from: item)
        dto.attachedAssignmentPublicID = after?.publicID
        return Output(
            contentItem: dto, wasVisibleToStudents: wasVisible,
            isVisibleToStudents: ContentItemVisibility.isVisibleToStudents(item, attachedTo: after))
    }

    /// The assignment the item is attached to now, if any.
    private static func attachedAssignment(
        of item: APICourseContentItem, on db: any Database
    ) async throws -> APIAssignment? {
        guard let assignmentID = item.assignmentID else { return nil }
        return try await APIAssignment.find(assignmentID, on: db)
    }
}
