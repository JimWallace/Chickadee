// APIServer/MCP/Tools/GetAssignmentTool.swift
//
// Read tool: returns one assignment's details by public ID. content:read.
// Course-scoped — the subject must be enrolled in the assignment's course
// (admins excepted). Full test-suite structure is available via get_suite.

import Core
import Fluent
import Foundation

struct GetAssignmentTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
    }

    struct Output: Encodable, Sendable {
        let publicID: String
        let title: String
        let slug: String
        let courseCode: String
        let isOpen: Bool
        /// Three-state visibility: "closed" | "preview" | "open". `isOpen` is the
        /// derived legacy flag (true only when "open").
        let visibility: String
        let dueAt: String?
        let startsAt: String?
        let validationStatus: String?
        let deadlineOverrideActive: Bool
        /// How submissions are graded: "worker" (native runner) or "browser"
        /// (in-browser Pyodide). Read from the test setup's manifest
        /// (`TestProperties.gradingMode`, default "worker").
        let gradingMode: String
        /// The course section (assignment group, e.g. "Labs") this assignment
        /// belongs to, or nil when ungrouped. Manage with set_assignment_section.
        let sectionID: String?
        let sectionName: String?
    }

    static let name = "get_assignment"
    static let description =
        "Get an assignment's details by its public ID: title, course code, slug, "
        + "visibility (closed/preview/open; preview is a staff-only beta state), the "
        + "derived isOpen flag, due date (ISO 8601), scheduled open date (ISO 8601, if any), "
        + "runner validation status, gradingMode (\"worker\" = graded by the native runner, "
        + "\"browser\" = graded in-browser via Pyodide), and the course section (assignment group "
        + "like \"Labs\") it belongs to (sectionID/sectionName, null when ungrouped)."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ])
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
            "courseCode": .object(["type": .string("string")]),
            "isOpen": .object(["type": .string("boolean")]),
            "visibility": .object([
                "type": .string("string"),
                "enum": .array([.string("closed"), .string("preview"), .string("open")]),
            ]),
            "dueAt": .object(["type": .string("string")]),
            "startsAt": .object(["type": .string("string")]),
            "validationStatus": .object(["type": .string("string")]),
            "deadlineOverrideActive": .object(["type": .string("boolean")]),
            "gradingMode": .object(["type": .string("string")]),
            "sectionID": .object(["type": .string("string")]),
            "sectionName": .object(["type": .string("string")]),
        ]),
        "required": .array([
            .string("publicID"), .string("title"), .string("slug"), .string("courseCode"),
            .string("isOpen"), .string("visibility"), .string("deadlineOverrideActive"),
            .string("gradingMode"),
        ]),
    ])
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        guard let assignment = try await assignmentByPublicID(input.assignmentPublicID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "No assignment found with public ID \"\(input.assignmentPublicID)\".")
        }
        try await context.authorizeCourseAccess(assignment.courseID, tool: Self.name)
        guard let course = try await APICourse.find(assignment.courseID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "The assignment's course could not be found.")
        }
        // Grading mode lives in the test setup's manifest; default to "worker"
        // (TestProperties' own default) when the setup or manifest is missing.
        let gradingMode =
            (try await APITestSetup.find(assignment.testSetupID, on: context.db))?
            .decodedManifest()?.gradingMode.rawValue ?? "worker"

        // Resolve the course section (assignment group) the assignment is in.
        var sectionName: String?
        if let sectionID = assignment.sectionID {
            sectionName = try await APICourseSection.find(sectionID, on: context.db)?.name
        }

        let formatter = ISO8601DateFormatter()
        return Output(
            publicID: assignment.publicID,
            title: assignment.title,
            slug: assignment.slug,
            courseCode: course.code,
            isOpen: assignment.isOpen,
            visibility: assignment.visibility.rawValue,
            dueAt: assignment.dueAt.map { formatter.string(from: $0) },
            startsAt: assignment.startsAt.map { formatter.string(from: $0) },
            validationStatus: assignment.validationStatus,
            deadlineOverrideActive: assignment.deadlineOverrideActive ?? false,
            gradingMode: gradingMode,
            sectionID: assignment.sectionID?.uuidString,
            sectionName: sectionName
        )
    }
}
