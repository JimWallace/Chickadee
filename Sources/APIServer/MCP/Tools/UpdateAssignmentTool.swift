// APIServer/MCP/Tools/UpdateAssignmentTool.swift
//
// Write tool: edit an assignment's metadata — title, due date, and/or
// open/closed state — by public ID. content:write, course-scoped. Metadata-only
// (no manifest change, so no regrade); routes through AssignmentAuthoringService
// so the semantics (title trim, due-date override normalisation, open/close
// validation guard) match the instructor editor exactly.

import Core
import Fluent
import Foundation

struct UpdateAssignmentTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        let title: String?
        let dueAt: String?
        let startsAt: String?
        let isOpen: Bool?

        init(
            assignmentPublicID: String, title: String? = nil, dueAt: String? = nil,
            startsAt: String? = nil, isOpen: Bool? = nil
        ) {
            self.assignmentPublicID = assignmentPublicID
            self.title = title
            self.dueAt = dueAt
            self.startsAt = startsAt
            self.isOpen = isOpen
        }
    }

    struct Output: Encodable, Sendable {
        let publicID: String
        let title: String
        let slug: String
        let isOpen: Bool
        let dueAt: String?
        let startsAt: String?
        let validationStatus: String?
    }

    static let name = "update_assignment"
    static let description =
        "Edit an assignment's metadata by its public ID. Provide only the fields you want to "
        + "change: title (non-empty), dueAt (ISO 8601 datetime, or an empty string to remove the "
        + "due date), startsAt (ISO 8601 automatic open date — the assignment opens to students on "
        + "its own when this time arrives — or an empty string to remove it), and/or isOpen (true to "
        + "open for submissions now — refused until runner validation passes, and clears any pending "
        + "open date — or false to close). Does not change test content, so it never triggers a regrade."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "title": .object([
                "type": .string("string"),
                "description": .string("New display title (non-empty)."),
            ]),
            "dueAt": .object([
                "type": .string("string"),
                "description": .string(
                    "Due date as an ISO 8601 datetime (e.g. \"2026-04-22T23:59:00Z\"), "
                        + "or an empty string to remove the due date."),
            ]),
            "startsAt": .object([
                "type": .string("string"),
                "description": .string(
                    "Automatic open date as an ISO 8601 datetime (e.g. \"2026-04-15T09:00:00Z\"). "
                        + "The assignment opens to students on its own once this time arrives. "
                        + "Pass an empty string to remove a scheduled open date."),
            ]),
            "isOpen": .object([
                "type": .string("boolean"),
                "description": .string("true to open the assignment for submissions, false to close it."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "publicID": .object(["type": .string("string")]),
            "title": .object(["type": .string("string")]),
            "slug": .object(["type": .string("string")]),
            "isOpen": .object(["type": .string("boolean")]),
            "dueAt": .object(["type": .string("string")]),
            "startsAt": .object(["type": .string("string")]),
            "validationStatus": .object(["type": .string("string")]),
        ]),
        "required": .array([
            .string("publicID"), .string("title"), .string("slug"), .string("isOpen"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let dueUpdate = try Self.resolveDueDate(input.dueAt)
        let startsUpdate = try Self.resolveStartDate(input.startsAt)
        let newTitle = try Self.resolveTitle(input.title)
        guard newTitle != nil || input.isOpen != nil || dueUpdate != .unchanged || startsUpdate != .unchanged
        else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "Specify at least one of: title, dueAt, startsAt, isOpen.")
        }

        guard let assignment = try await assignmentByPublicID(input.assignmentPublicID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "No assignment found with public ID \"\(input.assignmentPublicID)\".")
        }
        try await context.authorizeCourseAccess(assignment.courseID, tool: Self.name)
        do {
            try await AssignmentAuthoringService.updateMetadata(
                assignment, title: newTitle, dueAt: dueUpdate, startsAt: startsUpdate,
                open: input.isOpen, on: context.db)
        } catch AssignmentAuthoringError.validationNotPassed {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "The assignment cannot be opened until its runner validation has passed.")
        }

        let formatter = ISO8601DateFormatter()
        return Output(
            publicID: assignment.publicID,
            title: assignment.title,
            slug: assignment.slug,
            isOpen: assignment.isOpen,
            dueAt: assignment.dueAt.map { formatter.string(from: $0) },
            startsAt: assignment.startsAt.map { formatter.string(from: $0) },
            validationStatus: assignment.validationStatus
        )
    }

    /// Maps the optional `dueAt` argument to a `DueDateUpdate`: absent → no
    /// change, empty string → clear, ISO 8601 → set (else invalid).
    private static func resolveDueDate(_ raw: String?) throws -> DueDateUpdate {
        guard let raw else { return .unchanged }
        if raw.trimmingCharacters(in: .whitespaces).isEmpty { return .clear }
        guard let date = ISO8601DateFormatter().date(from: raw) else {
            throw MCPToolError.invalidArguments(
                tool: name,
                detail: "dueAt must be an ISO 8601 datetime (e.g. \"2026-04-22T23:59:00Z\") "
                    + "or an empty string to clear it.")
        }
        return .set(date)
    }

    /// Maps the optional `startsAt` argument to an `OpenDateUpdate`: absent → no
    /// change, empty string → clear, ISO 8601 → set (else invalid).
    private static func resolveStartDate(_ raw: String?) throws -> OpenDateUpdate {
        guard let raw else { return .unchanged }
        if raw.trimmingCharacters(in: .whitespaces).isEmpty { return .clear }
        guard let date = ISO8601DateFormatter().date(from: raw) else {
            throw MCPToolError.invalidArguments(
                tool: name,
                detail: "startsAt must be an ISO 8601 datetime (e.g. \"2026-04-15T09:00:00Z\") "
                    + "or an empty string to clear it.")
        }
        return .set(date)
    }

    /// Trims and validates the optional `title` argument (nil = no change).
    private static func resolveTitle(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPToolError.invalidArguments(tool: name, detail: "title must not be empty.")
        }
        return trimmed
    }
}
