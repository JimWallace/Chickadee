// APIServer/MCP/Tools/CloneAssignmentTool.swift
//
// Write tool: duplicate an existing assignment (its test setup zip, notebook,
// and manifest) into a new assignment under a new title. content:write,
// course-scoped on both the source and target course.
//
// This is the safe first cut at assignment *creation* (roadmap Phase 4a): rather
// than synthesizing a valid notebook + scripts from nothing, the agent clones a
// known-good assignment and then tweaks it with the Phase 1–3 tools
// (update_assignment / update_suite / update_pattern_family). The clone is made
// through AssignmentAuthoringService.cloneAssignment — the same per-assignment
// copy the admin "copy course" flow uses — so the two paths can't drift.
//
// The clone always lands closed, unvalidated, and with no due date: it's a
// brand-new test setup with no submissions, so nothing is re-graded. The
// instructor (or a follow-up update_assignment call) validates and opens it.

import Core
import Fluent
import Foundation

struct CloneAssignmentTool: ContentTool {
    struct Input: Decodable, Sendable {
        let sourceAssignmentPublicID: String
        let newTitle: String
        /// Course to clone into. Defaults to the source assignment's course.
        let targetCourseCode: String?
    }

    struct Output: Encodable, Sendable {
        let publicID: String
        let title: String
        let slug: String
        let courseCode: String
        let sourceAssignmentPublicID: String
        let isOpen: Bool
        let validationStatus: String?
    }

    static let name = "clone_assignment"
    static let description =
        "Duplicate an existing assignment into a new one by source public ID + new title. "
        + "Copies the test setup (scripts, manifest, pattern families) and notebook verbatim. "
        + "Optionally clone into another course (targetCourseCode); defaults to the same course. "
        + "The clone starts closed, unvalidated, and with no due date — edit it with update_suite / "
        + "update_pattern_family / update_assignment, then validate and open it. Nothing is re-graded."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "sourceAssignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("Public ID of the assignment to clone."),
            ]),
            "newTitle": .object([
                "type": .string("string"),
                "description": .string("Title for the new assignment."),
            ]),
            "targetCourseCode": .object([
                "type": .string("string"),
                "description": .string(
                    "Course code to clone into. Omit to clone within the source's own course."),
            ]),
        ]),
        "required": .array([
            .string("sourceAssignmentPublicID"), .string("newTitle"),
        ]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "publicID": .object(["type": .string("string")]),
            "title": .object(["type": .string("string")]),
            "slug": .object(["type": .string("string")]),
            "courseCode": .object(["type": .string("string")]),
            "sourceAssignmentPublicID": .object(["type": .string("string")]),
            "isOpen": .object(["type": .string("boolean")]),
            "validationStatus": .object(["type": .string("string")]),
        ]),
        "required": .array([
            .string("publicID"), .string("title"), .string("slug"), .string("courseCode"),
            .string("sourceAssignmentPublicID"), .string("isOpen"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let title = input.newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw MCPToolError.invalidArguments(tool: Self.name, detail: "newTitle must not be empty.")
        }

        guard
            let source = try await assignmentByPublicID(
                input.sourceAssignmentPublicID, on: context.db)
        else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "No assignment found with public ID \"\(input.sourceAssignmentPublicID)\".")
        }
        try await context.authorizeCourseAccess(source.courseID, tool: Self.name)

        guard let sourceSetup = try await APITestSetup.find(source.testSetupID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "The source assignment's test setup could not be found.")
        }

        // Resolve the target course: same as source unless a code is given.
        let targetCourseID: UUID
        if let code = input.targetCourseCode?.trimmingCharacters(in: .whitespacesAndNewlines),
            !code.isEmpty
        {
            guard
                let target = try await APICourse.query(on: context.db)
                    .filter(\.$code == code).first()
            else {
                throw MCPToolError.invalidArguments(
                    tool: Self.name, detail: "No course found with code \"\(code)\".")
            }
            targetCourseID = try target.requireID()
            // Must be authorized for the destination course too.
            try await context.authorizeCourseAccess(targetCourseID, tool: Self.name)
        } else {
            targetCourseID = source.courseID
        }

        let cloned: AuthoredAssignment
        do {
            cloned = try await AssignmentAuthoringService.cloneAssignment(
                source: source,
                sourceSetup: sourceSetup,
                newTitle: title,
                targetCourseID: targetCourseID,
                setupsDirectory: context.request.application.testSetupsDirectory,
                on: context.db)
        } catch let error as AssignmentAuthoringError {
            switch error {
            case .setupCopyFailed(let reason):
                throw MCPToolError.executionFailed(
                    tool: Self.name, detail: "Could not copy the source test setup: \(reason)")
            case .validationNotPassed:
                throw MCPToolError.executionFailed(tool: Self.name, detail: "\(error)")
            }
        }

        let courseCode =
            try await APICourse.find(targetCourseID, on: context.db)?.code ?? ""
        return Output(
            publicID: cloned.assignment.publicID,
            title: cloned.assignment.title,
            slug: cloned.assignment.slug,
            courseCode: courseCode,
            sourceAssignmentPublicID: source.publicID,
            isOpen: cloned.assignment.isOpen,
            validationStatus: cloned.assignment.validationStatus)
    }
}
