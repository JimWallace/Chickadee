// APIServer/MCP/Tools/MCPWebErrorMapping.swift
//
// Several write tools reuse the server-authoritative web edit paths, which
// raise `WebAssignmentError` (an HTTP-shaped error).  Over MCP those need to
// become `MCPToolError` so the dispatcher surfaces a clean JSON-RPC error to
// the agent rather than an opaque internal failure.  Validation-class failures
// (bad input the agent can fix) map to `invalidArguments`; genuine server-side
// failures map to `executionFailed`.

import Foundation

extension MCPToolError {
    /// Translates a `WebAssignmentError` raised by a shared web edit path into
    /// the MCP error vocabulary, attributed to `tool`.
    static func from(_ error: WebAssignmentError, tool: String) -> MCPToolError {
        switch error {
        case .internalFailure:
            return .executionFailed(tool: tool, detail: error.reason)
        case .notFound, .invalidParameter, .noActiveCourse, .forbidden, .conflict,
            .unprocessable, .validationRequired:
            return .invalidArguments(tool: tool, detail: error.reason)
        }
    }
}
