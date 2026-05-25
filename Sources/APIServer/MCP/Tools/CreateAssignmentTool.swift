// APIServer/MCP/Tools/CreateAssignmentTool.swift
//
// Write tool: create a brand-new browser-graded, notebook-based assignment from
// scratch in a course, by course code + title + starter notebook (.ipynb JSON).
// content:write, course-scoped.
//
// This is the structured-spec creation path (roadmap Phase 4b), built on the
// pieces proven by the earlier phases: it assembles a minimal empty-suite
// manifest + an empty runner zip + the supplied notebook through
// AssignmentAuthoringService.createAssignment (the same per-setup work the web
// new-assignment publish does, minus the draft scaffolding), then the agent
// fills in tests with update_suite / update_pattern_family and refines the
// notebook with update_notebook.
//
// The assignment lands closed, unvalidated, and with no due date. Because it
// starts with an empty suite, no validation run is queued — the instructor can
// open it once it has content.

import Core
import Fluent
import Foundation

struct CreateAssignmentTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
        let title: String
        let notebook: JSONValue
    }

    struct Output: Encodable, Sendable {
        let publicID: String
        let title: String
        let slug: String
        let courseCode: String
        let cellCount: Int
        let isOpen: Bool
    }

    static let name = "create_assignment"
    static let description =
        "Create a new browser-graded, notebook-based assignment from scratch in a course, by course "
        + "code + title + starter notebook (.ipynb JSON object with a \"cells\" array). The new "
        + "assignment starts closed, unvalidated, with no due date and an empty test suite — add tests "
        + "with update_suite / update_pattern_family and refine the notebook with update_notebook, then "
        + "open it. To duplicate an existing assignment instead, use clone_assignment."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": .object([
                "type": .string("string"),
                "description": .string("Code of the course to create the assignment in."),
            ]),
            "title": .object([
                "type": .string("string"),
                "description": .string("Title for the new assignment."),
            ]),
            "notebook": .object([
                "type": .string("object"),
                "description": .string(
                    "The starter notebook as .ipynb JSON (an object containing a \"cells\" array)."),
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("title"), .string("notebook")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "publicID": .object(["type": .string("string")]),
            "title": .object(["type": .string("string")]),
            "slug": .object(["type": .string("string")]),
            "courseCode": .object(["type": .string("string")]),
            "cellCount": .object(["type": .string("integer")]),
            "isOpen": .object(["type": .string("boolean")]),
        ]),
        "required": .array([
            .string("publicID"), .string("title"), .string("slug"), .string("courseCode"),
            .string("cellCount"), .string("isOpen"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw MCPToolError.invalidArguments(tool: Self.name, detail: "title must not be empty.")
        }
        try Self.validateNotebookShape(input.notebook)

        let code = input.courseCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let course = try await APICourse.query(on: context.db).filter(\.$code == code).first()
        else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "No course found with code \"\(code)\".")
        }
        let courseID = try course.requireID()
        try await context.authorizeCourseAccess(courseID, tool: Self.name)

        let data: Data
        do {
            data = try JSONEncoder().encode(input.notebook)
        } catch {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "The notebook could not be serialized to JSON.")
        }

        let created: AuthoredAssignment
        do {
            created = try await AssignmentAuthoringService.createAssignment(
                courseID: courseID, title: title, notebookData: data,
                setupsDirectory: context.request.application.testSetupsDirectory, on: context.db)
        } catch let error as AssignmentAuthoringError {
            if case .setupCopyFailed(let reason) = error {
                throw MCPToolError.executionFailed(
                    tool: Self.name, detail: "Could not create the test setup: \(reason)")
            }
            throw MCPToolError.executionFailed(tool: Self.name, detail: "\(error)")
        }

        return Output(
            publicID: created.assignment.publicID,
            title: created.assignment.title,
            slug: created.assignment.slug,
            courseCode: course.code,
            cellCount: Self.cellCount(of: input.notebook),
            isOpen: created.assignment.isOpen)
    }

    private static func validateNotebookShape(_ notebook: JSONValue) throws {
        guard case .object(let root) = notebook else {
            throw MCPToolError.invalidArguments(
                tool: name, detail: "notebook must be a JSON object.")
        }
        guard case .array? = root["cells"] else {
            throw MCPToolError.invalidArguments(
                tool: name, detail: "notebook must contain a \"cells\" array.")
        }
    }

    private static func cellCount(of notebook: JSONValue) -> Int {
        guard case .object(let root) = notebook, case .array(let cells)? = root["cells"] else {
            return 0
        }
        return cells.count
    }
}
