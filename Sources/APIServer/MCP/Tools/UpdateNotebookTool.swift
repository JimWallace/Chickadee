// APIServer/MCP/Tools/UpdateNotebookTool.swift
//
// Write tool: replace an assignment's starter notebook with new .ipynb JSON
// supplied by the agent, by assignment public ID. content:write, course-scoped.
//
// The agent supplies the full notebook JSON (the format decided for notebook
// writes); the server applies the same JupyterLite kernel normalization + flat-
// file write the web editor's Save uses (AssignmentAuthoringService.write
// AssignmentNotebook), then re-enqueues validation exactly like the suite-edit
// tools, so the two paths can't drift and the validation loop stays closed.
//
// Deliberately narrow blast radius: only the flat `<setupID>.ipynb` is written
// (the setup zip stays archival — reads prefer the flat file), and existing
// student working copies are left untouched so a notebook edit never clobbers a
// student's in-progress work. Students pick up the new starter notebook the
// next time their working copy is (re)seeded.

import Core
import Fluent
import Foundation

struct UpdateNotebookTool: ContentTool {
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

    static let name = "update_notebook"
    static let description =
        "Replace an assignment's starter notebook (the notebook students open) with new .ipynb JSON, "
        + "by assignment public ID. Supply the full notebook as a JSON object with a \"cells\" array; "
        + "the server normalizes it for the in-browser kernel and re-runs validation, closing the "
        + "assignment if it was open (re-open with update_assignment once validation passes). Only the "
        + "starter notebook changes — existing students keep their in-progress work and pick up the new "
        + "notebook when their copy is next reset. Use get_notebook first to fetch the current notebook "
        + "to edit."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "notebook": .object([
                "type": .string("object"),
                "description": .string(
                    "The full notebook as .ipynb JSON (must be an object containing a \"cells\" array)."
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

        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, tool: Self.name, atLeast: .ta)

        let data: Data
        do {
            data = try JSONEncoder().encode(input.notebook)
        } catch {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "The notebook could not be serialized to JSON.")
        }

        do {
            try await AssignmentAuthoringService.writeAssignmentNotebook(
                setup: setup, notebookData: data,
                setupsDirectory: context.request.application.testSetupsDirectory, on: context.db)
        } catch let error as AssignmentAuthoringError {
            if case .setupCopyFailed(let reason) = error {
                throw MCPToolError.executionFailed(
                    tool: Self.name, detail: "Could not write the notebook: \(reason)")
            }
            throw MCPToolError.executionFailed(tool: Self.name, detail: "\(error)")
        }

        // Starter-notebook edit: close + re-validate, no regrade of submissions.
        let finalized = try await finalizeContentEdit(
            assignment: assignment, setup: setup, context: context, retest: false)

        return Output(
            assignmentPublicID: assignment.publicID,
            cellCount: notebookCellCount(input.notebook),
            validationStatus: assignment.validationStatus,
            assignmentClosed: finalized.assignmentClosed)
    }

}
