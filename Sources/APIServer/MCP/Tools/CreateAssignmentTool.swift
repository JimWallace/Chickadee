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
        /// An `AssignmentLanguage` raw value, or `"none"` for a shell-script
        /// suite. Required — see the schema description.
        let language: String
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
            "language": .object([
                "type": .string("string"),
                "enum": .array(
                    AssignmentLanguage.allCases.map { .string($0.rawValue) }
                        + [.string(noLanguageChoice)]),
                "description": .string(
                    "The language this assignment is authored and graded in, or \"none\" for a suite "
                        + "of plain shell scripts. Required: the language is what every generated test "
                        + "renders in, so it is stated rather than guessed. Declaring "
                        + "\(LanguageProse.uploadOnlyTokens) also sets submissionMode to uploadOnly, "
                        + "since those languages have no notebook workflow."),
            ]),
        ]),
        "required": .array([
            .string("courseCode"), .string("title"), .string("notebook"), .string("language"),
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
            "cellCount": MCPSchema.integer,
            "isOpen": MCPSchema.boolean,
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
        try validateNotebookShape(input.notebook, tool: Self.name)
        // Parsed BEFORE the course lookup and the setup write, so an unusable
        // language fails without leaving a half-created assignment behind.
        let declaredLanguage: AssignmentLanguage?
        do {
            declaredLanguage = try parseLanguageChoice(input.language)
        } catch {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: unknownLanguageMessage(input.language))
        }

        let code = input.courseCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let course = try await APICourse.query(on: context.db).filter(\.$code == code).first()
        else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "No course found with code \"\(code)\".")
        }
        let courseID = try course.requireID()
        // Creating an assignment is instructor-level (#417); archived is blocked too.
        try await context.authorizeCourseWriteAccess(courseID, tool: Self.name, atLeast: .instructor)

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

        try await declareManifestLanguage(
            setup: created.setup, to: declaredLanguage, on: context.db)

        await AuditLogger.recordAssignmentLifecycle(
            .assignmentCreated, assignment: created.assignment,
            metadata: ["title": created.assignment.title, "via": "mcp"], on: context.request)

        return Output(
            publicID: created.assignment.publicID,
            title: created.assignment.title,
            slug: created.assignment.slug,
            courseCode: course.code,
            cellCount: notebookCellCount(input.notebook),
            isOpen: created.assignment.isOpen)
    }

}
