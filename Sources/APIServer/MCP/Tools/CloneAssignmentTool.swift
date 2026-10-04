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
        /// The key and term of the course acted on; see `MCPSchema.courseKeyOutput`.
        let courseKey: String
        let courseTerm: String?
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
                    "The course to clone into: its code, or its key with the term (e.g. "
                        + "\"CS136-F26\") when several offerings share the code. Omit to clone "
                        + "within the source's own course."),
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
            "publicID": MCPSchema.string,
            "title": MCPSchema.string,
            "slug": MCPSchema.string,
            "courseCode": MCPSchema.string,
            "courseKey": MCPSchema.courseKeyOutput,
            "courseTerm": MCPSchema.courseTermOutput,
            "sourceAssignmentPublicID": MCPSchema.string,
            "isOpen": MCPSchema.boolean,
            "validationStatus": MCPSchema.string,
        ]),
        "required": .array([
            .string("publicID"), .string("title"), .string("slug"), .string("courseCode"),
            .string("courseKey"),
            .string("sourceAssignmentPublicID"), .string("isOpen"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let title = input.newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw MCPToolError.invalidArguments(detail: "newTitle must not be empty.")
        }

        let source = try await context.authorizedAssignment(
            publicID: input.sourceAssignmentPublicID)

        guard let sourceSetup = try await APITestSetup.find(source.testSetupID, on: context.db) else {
            throw MCPToolError.invalidArguments(detail: "The source assignment's test setup could not be found.")
        }

        // Resolve the target course: same as source unless a code is given.
        let targetCourse: APICourse
        if let code = input.targetCourseCode?.trimmingCharacters(in: .whitespacesAndNewlines),
            !code.isEmpty
        {
            targetCourse = try await resolveMCPCourse(
                key: code, context: context, forWrite: true)
        } else {
            guard let sourceCourse = try await APICourse.find(source.courseID, on: context.db) else {
                throw MCPToolError.invalidArguments(detail: "The source assignment's course could not be found.")
            }
            targetCourse = sourceCourse
        }
        let targetCourseID = try targetCourse.requireID()
        // The clone WRITES a new assignment into the target course, so block an
        // archived destination (covers both the explicit-target and
        // default-to-source branches). The source stays read-authorized above —
        // reviving an archived course's content into a live course is fine; only
        // the destination is write-gated (#417 Slice D-MCP).
        // Creating an assignment (clone) into the destination is instructor-level (#417).
        try await context.authorizeCourseWriteAccess(
            targetCourseID, atLeast: .instructor)

        let cloned: AuthoredAssignment
        do {
            cloned = try await AssignmentAuthoringService.cloneAssignment(
                source: source,
                sourceSetup: sourceSetup,
                newTitle: title,
                targetCourseID: targetCourseID,
                directories: AuthoringDirectories(
                    setups: context.request.application.testSetupsDirectory,
                    submissions: context.request.application.submissionsDirectory),
                on: context.db)
        } catch let error as AssignmentAuthoringError {
            switch error {
            case .setupCopyFailed(let reason):
                throw MCPToolError.executionFailed(detail: "Could not copy the source test setup: \(reason)")
            case .validationNotPassed:
                throw MCPToolError.executionFailed(detail: "\(error)")
            }
        }

        await AuditLogger.recordAssignmentLifecycle(
            .assignmentCloned, assignment: cloned.assignment,
            metadata: [
                "source_assignment": source.publicID, "title": cloned.assignment.title,
                "via": "mcp",
            ], on: context.request)

        return Output(
            publicID: cloned.assignment.publicID,
            title: cloned.assignment.title,
            slug: cloned.assignment.slug,
            courseCode: targetCourse.code,
            courseKey: targetCourse.urlKey,
            courseTerm: targetCourse.term?.displayName,
            sourceAssignmentPublicID: source.publicID,
            isOpen: cloned.assignment.isOpen,
            validationStatus: cloned.assignment.validationStatus)
    }
}
