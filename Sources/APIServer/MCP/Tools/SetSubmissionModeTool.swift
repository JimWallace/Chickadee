// APIServer/MCP/Tools/SetSubmissionModeTool.swift
//
// Write tool: set how students hand work in — "notebook" (the embedded editor,
// with the upload form beside it) or "uploadOnly" (file upload and nothing
// else) — by assignment public ID. content:write, course-scoped.
//
// The web edit page has had this control since the submission-mode slice; this
// is its MCP twin, so an agent can author the upload-only assignments C++
// requires without a human visiting the form. Both call the same
// `setManifestSubmissionMode`, so the two refusals below are enforced once.

import Core
import Fluent
import Foundation

struct SetSubmissionModeTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// "notebook" or "uploadOnly".
        let submissionMode: String
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let submissionMode: String
        /// The mode the assignment is actually graded in. `uploadOnly` pins
        /// this to "worker" — reported so a caller that flipped the mode sees
        /// the grading path move with it rather than discovering it later.
        let gradingMode: String
    }

    static let name = "set_submission_mode"
    static let description =
        "Set how students hand work in for an assignment by its public ID: \"notebook\" (the embedded "
        + "editor, with the upload form beside it) or \"uploadOnly\" (file upload only, no editor). Use "
        + "uploadOnly for a language with no in-browser kernel — C++ assignments must be uploadOnly, and "
        + "set_assignment_language refuses C++ until they are. An uploadOnly assignment is always graded "
        + "by the native worker, so switch the grading mode to \"worker\" first (set_grading_mode); this "
        + "tool refuses the browser combination rather than storing a value that could never execute. "
        + "Read the current mode from get_assignment."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "submissionMode": .object([
                "type": .string("string"),
                "enum": .array([.string("notebook"), .string("uploadOnly")]),
                "description": .string(
                    "\"notebook\" (embedded editor plus upload form) or \"uploadOnly\" (upload only)."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("submissionMode")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "submissionMode": MCPSchema.string,
            "gradingMode": MCPSchema.string,
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("submissionMode"), .string("gradingMode"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let mode = input.submissionMode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = SubmissionMode(rawValue: mode) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "submissionMode must be \"notebook\" or \"uploadOnly\".")
        }
        // How students submit is a lifecycle setting — instructor-level (#417),
        // matching set_grading_mode.
        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, tool: Self.name, atLeast: .instructor)
        // Surface both of the shared helper's refusals as arguments errors, so
        // an agent reads a fixable message rather than a 400. The helper keeps
        // its own guards as the backstop for any path that skips this.
        if parsed == .uploadOnly,
            currentManifestGradingMode(setup.manifest) == GradingMode.browser.rawValue
        {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: uploadModeGradingConflictMessage)
        }
        if parsed == .notebook,
            currentManifestLanguage(setup.manifest) == AssignmentLanguage.cpp.rawValue
        {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: cppRequiresUploadOnlyMessage)
        }
        let effective = try await setManifestSubmissionMode(
            setup: setup, to: mode, on: context.db)
        return Output(
            assignmentPublicID: assignment.publicID,
            submissionMode: effective,
            gradingMode: effective == SubmissionMode.uploadOnly.rawValue
                ? GradingMode.worker.rawValue : currentManifestGradingMode(setup.manifest))
    }
}
