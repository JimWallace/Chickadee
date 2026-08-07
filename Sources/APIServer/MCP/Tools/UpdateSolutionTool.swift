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
// that). The MCP bearer context carries no session-authenticated user, so the
// resolved subject is threaded to the enqueue helper as the submission's author.

import Core
import Fluent
import Foundation

struct UpdateSolutionTool: ContentTool {
    /// A reference solution supplied as a source FILE rather than a notebook —
    /// the only shape available to an upload-only language. C++ is the case
    /// that needs it: it has no notebook workflow, so there is no `.ipynb` to
    /// extract source from and a notebook solution could never be graded.
    struct SolutionFile: Decodable, Sendable {
        let filename: String
        let content: String
    }

    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// Exactly one of `notebook` / `solutionFile` is supplied.
        let notebook: JSONValue?
        let solutionFile: SolutionFile?

        /// Spelled out rather than left to the memberwise synthesis so each
        /// alternative reads as optional at the call site.
        init(
            assignmentPublicID: String, notebook: JSONValue? = nil,
            solutionFile: SolutionFile? = nil
        ) {
            self.assignmentPublicID = assignmentPublicID
            self.notebook = notebook
            self.solutionFile = solutionFile
        }
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        /// 0 for a source-file solution, which has no cells.
        let cellCount: Int
        /// The name the solution was stored under — "solution.ipynb" for a
        /// notebook, the supplied filename for a source file.
        let solutionFilename: String
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
        + "define the variable — see docs/personalization-solution-notebooks.md). For a language with "
        + "no notebook workflow (C++), pass solutionFile instead — a single source file "
        + "({filename, content}) — since there is no notebook to extract the answer key from; passing "
        + "a notebook for such an assignment is refused. Supply exactly one of notebook / solutionFile."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "notebook": .object([
                "type": .string("object"),
                "description": .string(
                    "The full solution notebook as .ipynb JSON (an object containing a \"cells\" array). "
                        + "Use for a notebook-workflow assignment; omit when passing solutionFile."
                ),
            ]),
            "solutionFile": .object([
                "type": .string("object"),
                "description": .string(
                    "The reference solution as ONE source file, for an assignment whose language has no "
                        + "notebook workflow (C++). Omit when passing notebook."),
                "properties": .object([
                    "filename": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Bare filename with no path separators, e.g. \"solution.cpp\". Its extension "
                                + "must be one the assignment's language recognizes."),
                    ]),
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("The full file body."),
                    ]),
                ]),
                "required": .array([.string("filename"), .string("content")]),
                "additionalProperties": .bool(false),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "cellCount": MCPSchema.integer,
            "solutionFilename": MCPSchema.string,
            "validationStatus": MCPSchema.string,
            "assignmentClosed": MCPSchema.boolean,
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("cellCount"), .string("solutionFilename"),
            .string("assignmentClosed"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: true, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        guard (input.notebook == nil) != (input.solutionFile == nil) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "Supply exactly one of notebook / solutionFile.")
        }
        if let notebook = input.notebook {
            try validateNotebookShape(notebook, tool: Self.name)
        }

        let assignment = try await context.authorizedAssignmentForWrite(
            publicID: input.assignmentPublicID, tool: Self.name, atLeast: .ta)
        // The bearer context has no session-authenticated user; resolve the
        // subject so the validation submission is attributed to the acting account.
        let subject = try await context.requireEligibleSubject(tool: Self.name)

        // Content versioning: this tool reaches its setup by id rather than
        // through `authorizedAssignmentAndSetupForWrite`, so it registers for a
        // snapshot by hand. Replacing the reference solution rewrites the
        // solution file inside the setup zip, which is versioned content.
        let setup = try await APITestSetup.find(assignment.testSetupID, on: context.db)
        if let setup {
            await context.beginContentWrite(setup: setup)
        }

        // Which shape this assignment's answer key can take is decided by its
        // language, not by the caller's preference: a language with no notebook
        // workflow has no `.ipynb` to extract source from, so a notebook
        // solution would be stored and then grade as an empty submission.
        let language =
            setup?.decodedManifest().map {
                AssignmentLanguage.resolve(manifest: $0, notebookData: nil)
            } ?? .default
        let wantsSourceFile: Bool
        if case .uploadOnly = language.editorSupport {
            wantsSourceFile = true
        } else {
            wantsSourceFile = false
        }
        if wantsSourceFile, input.notebook != nil {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail:
                    "\(language.rawValue) has no notebook workflow, so a notebook cannot serve as its "
                    + "reference solution. Pass solutionFile ({filename, content}) instead.")
        }

        let data: Data
        let storedFilename: String
        let cellCount: Int
        if let file = input.solutionFile {
            let name = file.filename.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".",
                name != ".."
            else {
                throw MCPToolError.invalidArguments(
                    tool: Self.name,
                    detail: "solutionFile.filename must be a bare filename with no path separators.")
            }
            let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
            guard language.scriptExtensions.contains(ext) else {
                let allowed = language.scriptExtensions.sorted().joined(separator: ", ")
                throw MCPToolError.invalidArguments(
                    tool: Self.name,
                    detail:
                        "solutionFile.filename must end in an extension \(language.rawValue) "
                        + "recognizes (\(allowed)); got \"\(name)\".")
            }
            data = Data(file.content.utf8)
            storedFilename = name
            cellCount = 0
        } else {
            do {
                data = normalizeNotebookForJupyterLite(try JSONEncoder().encode(input.notebook))
            } catch {
                throw MCPToolError.invalidArguments(
                    tool: Self.name, detail: "The notebook could not be serialized to JSON.")
            }
            storedFilename = "solution.ipynb"
            cellCount = notebookCellCount(input.notebook ?? .null)
        }

        let validationSubmissionID: String
        do {
            validationSubmissionID = try await enqueueRunnerValidationSubmission(
                req: context.request,
                setupID: assignment.testSetupID,
                solutionNotebookData: data,
                filename: storedFilename,
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
            cellCount: cellCount,
            solutionFilename: storedFilename,
            validationStatus: assignment.validationStatus,
            assignmentClosed: closed)
    }

}
