// APIServer/MCP/Tools/GetNotebookTool.swift
//
// Read tool: returns an assignment's notebook (the starter/assignment notebook
// the student opens) as structured .ipynb JSON, by assignment public ID.
// content:read, course-scoped.
//
// This is the first, read-only slice of notebook authoring (roadmap Phase 5):
// an agent needs to see the current notebook before it can reason about or
// (later) edit it. Loading reuses the canonical `notebookData(for:)` helper —
// the same flat-file-then-zip resolution + JupyterLite normalization the web
// notebook routes use — so the agent sees exactly what the editor would.
//
// No cell filtering: only instructors / admins / mcp service accounts can use
// MCP at all (students are rejected at the tool layer), so the full notebook is
// returned the way an instructor download would.

import Core
import Fluent
import Foundation

struct GetNotebookTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let cellCount: Int
        let notebook: JSONValue
    }

    static let name = "get_notebook"
    static let description =
        "Get an assignment's notebook (the starter notebook students open) as .ipynb JSON, by "
        + "assignment public ID. Returns the full notebook plus a cell count. Read-only; use it to "
        + "inspect an assignment's notebook before editing the suite or (later) the notebook itself."
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
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        guard let assignment = try await assignmentByPublicID(input.assignmentPublicID, on: context.db)
        else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "No assignment found with public ID \"\(input.assignmentPublicID)\".")
        }
        try await context.authorizeCourseAccess(assignment.courseID, tool: Self.name)

        guard let setup = try await APITestSetup.find(assignment.testSetupID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "The assignment's test setup could not be found.")
        }

        let data: Data
        do {
            data = try notebookData(for: setup)
        } catch {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "This assignment has no notebook to return.")
        }

        let notebook: JSONValue
        do {
            notebook = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw MCPToolError.executionFailed(
                tool: Self.name, detail: "The stored notebook is not valid JSON.")
        }

        return Output(
            assignmentPublicID: assignment.publicID,
            cellCount: Self.cellCount(of: notebook),
            notebook: notebook)
    }

    /// Number of cells in the notebook, or 0 if the `cells` array is absent.
    private static func cellCount(of notebook: JSONValue) -> Int {
        guard case .object(let root) = notebook, case .array(let cells)? = root["cells"] else {
            return 0
        }
        return cells.count
    }
}
