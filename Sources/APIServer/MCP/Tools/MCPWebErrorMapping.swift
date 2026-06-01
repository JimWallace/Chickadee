// APIServer/MCP/Tools/MCPWebErrorMapping.swift
//
// Several write tools reuse the server-authoritative web edit paths, which
// raise `WebAssignmentError` (an HTTP-shaped error).  Over MCP those need to
// become `MCPToolError` so the dispatcher surfaces a clean JSON-RPC error to
// the agent rather than an opaque internal failure.  Validation-class failures
// (bad input the agent can fix) map to `invalidArguments`; genuine server-side
// failures map to `executionFailed`.

import Foundation
import Vapor

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

    /// Translates a Vapor `AbortError` (e.g. the `Abort(.unprocessableEntity,
    /// …)` that pattern-family validation throws) into the MCP vocabulary.
    /// Client-fixable 4xx failures become `invalidArguments`; anything else is
    /// a genuine server-side failure.
    static func from(_ error: any AbortError, tool: String) -> MCPToolError {
        if (400..<500).contains(Int(error.status.code)) {
            return .invalidArguments(tool: tool, detail: error.reason)
        }
        return .executionFailed(tool: tool, detail: error.reason)
    }
}
