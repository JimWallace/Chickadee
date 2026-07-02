// APIServer/MCP/Tools/UpdateSolutionTool.swift
//
// Write tool: replace an assignment's reference SOLUTION notebook (the
// instructor's answer key) with new .ipynb JSON, by assignment public ID.
// content:write, course-scoped.
//
// Mirrors the web edit flow's "replace solution + re-validate" path: the new
// notebook is normalized for the in-browser kernel, stored as a fresh
// `kind == .validation` submission via the shared enqueue helper, linked as the
// assignment's validation submission, and validation is flipped to "pending"
// so the runner regrades the solution against the current suite. The agent
// watches the outcome with validate_assignment (which reports
// passed/failed/no-runner), exactly as after a suite edit.
//
// This only ever touches the instructor's solution/validation submission — never
// a student submission, and never the starter notebook (use update_notebook for
// that). The MCP bearer context has no `Request.auth` APIUser, so the resolved
// subject is threaded to the enqueue helper as the submission's author.

import Core
import Fluent
import Foundation

struct UpdateSolutionTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        let notebook: JSONValue
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let cellCount: Int
        let validationStatus: String?
        /// true when this edit closed a previously-open assignment (re-open with
        /// update_assignment once validation passes).
        let assignmentClosed: Bool
    }

    static let name = "update_solution"
    static let description =
        "Replace an assignment's reference SOLUTION notebook (the instructor's answer key used to "
        + "validate the test suite) with new .ipynb JSON, by assignment public ID. Supply the full "
        + "notebook as a JSON object with a \"cells\" array; the server stores it as a new validation "
        + "submission and re-runs validation against the current suite (watch the result with "
        + "validate_assignment), closing the assignment if it was open (re-open with update_assignment "
        + "once validation passes). This is instructor-authored content — it never touches student "
        + "submissions, and never the starter notebook (use update_notebook for that). Use get_solution "
        + "first to fetch the current solution to edit. The solution may use `{{name}}` personalization "
        + "placeholders just like the starter notebook (declare `name` in global inputs); they are "
        + "substituted per validation-seed at grading, which is the supported way to give a seed-agnostic "
        + "answer key a per-student VARIABLE value (a module-level assignment that COMPUTES the value via "
        + "a function call, e.g. reading CHICKADEE_ASSIGNMENT_SEED, is quarantined at import and won't "
        + "define the variable — see docs/personalization-solution-notebooks.md)."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "notebook": .object([
                "type": .string("object"),
                "description": .string(
                    "The full solution notebook as .ipynb JSON (an object containing a \"cells\" array)."
                ),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("notebook")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "cellCount": MCPSchema.integer,
            "validationStatus": MCPSchema.string,
            "assignmentClosed": MCPSchema.boolean,
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("cellCount"), .string("assignmentClosed"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: true, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        try validateNotebookShape(input.notebook, tool: Self.name)

        let assignment = try await context.authorizedAssignmentForWrite(
            publicID: input.assignmentPublicID, tool: Self.name, atLeast: .ta)
        // The bearer context has no `Request.auth` APIUser; resolve the subject
        // so the validation submission is attributed to the acting account.
        let subject = try await context.requireEligibleSubject(tool: Self.name)

        let data: Data
        do {
            data = try JSONEncoder().encode(input.notebook)
        } catch {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "The notebook could not be serialized to JSON.")
        }
        let normalized = normalizeNotebookForJupyterLite(data)

        let validationSubmissionID: String
        do {
            validationSubmissionID = try await enqueueRunnerValidationSubmission(
                req: context.request,
                setupID: assignment.testSetupID,
                solutionNotebookData: normalized,
                filename: "solution.ipynb",
                submitterUserID: subject.id)
        } catch {
            throw MCPToolError.executionFailed(
                tool: Self.name, detail: "Could not store the solution for validation: \(error)")
        }

        // Close a currently-open assignment through the shared content-edit
        // rule (#1115 — this used to be a hand-rolled copy of it) so students
        // can't submit against the not-yet-revalidated solution/suite. This
        // tool deliberately does NOT go through `finalizeContentEdit`: it has
        // already enqueued its own validation carrying the NEW solution above
        // (scheduleValidationAfterSuiteEdit would re-run against the old one),
        // and a solution-only edit never changes the test manifest, so the
        // manifest-gated regrade would be a no-op (matching the web save path).
        let closed = try await closeOpenAssignmentForContentEdit(assignment, on: context.db)
        assignment.validationSubmissionID = validationSubmissionID
        assignment.validationStatus = "pending"
        try await assignment.save(on: context.db)

        return Output(
            assignmentPublicID: assignment.publicID,
            cellCount: notebookCellCount(input.notebook),
            validationStatus: assignment.validationStatus,
            assignmentClosed: closed)
    }

}
