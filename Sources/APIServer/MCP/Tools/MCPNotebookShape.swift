// APIServer/MCP/Tools/MCPNotebookShape.swift
//
// Shared notebook-JSON shape helpers for the MCP tools that accept or return a
// notebook (`create_assignment`, `update_notebook`, `get_notebook`,
// `get_solution`, `update_solution`). Each tool previously carried byte-identical
// private copies of these.

import Core

/// Number of cells in a notebook JSON object (0 if it isn't the expected shape).
func notebookCellCount(_ notebook: JSONValue) -> Int {
    guard case .object(let root) = notebook, case .array(let cells)? = root["cells"] else {
        return 0
    }
    return cells.count
}

/// Validates the minimal shape every Jupyter notebook has: a JSON object with a
/// `cells` array. Stricter nbformat checks are left to the runner, matching the
/// web save path's lenient JSON-only validation.
func validateNotebookShape(_ notebook: JSONValue, tool: String) throws {
    guard case .object(let root) = notebook else {
        throw MCPToolError.invalidArguments(tool: tool, detail: "notebook must be a JSON object.")
    }
    guard case .array? = root["cells"] else {
        throw MCPToolError.invalidArguments(
            tool: tool, detail: "notebook must contain a \"cells\" array.")
    }
}
