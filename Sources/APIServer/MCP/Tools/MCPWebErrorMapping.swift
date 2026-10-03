// APIServer/MCP/Tools/MCPWebErrorMapping.swift
//
// Several write tools reuse the server-authoritative web edit paths, which
// raise `WebAssignmentError` (an HTTP-shaped error) or a Vapor `Abort`. Over
// MCP those need to become `MCPToolError` so the dispatcher surfaces a clean
// JSON-RPC error to the agent rather than an opaque internal failure.
// Validation-class failures (bad input the agent can fix) map to
// `invalidArguments`; genuine server-side failures map to `executionFailed`.
//
// `AnyContentTool.invoke` maps every 4xx for every tool. The explicit catches
// in some tools remain because tests call `execute` directly (#1940).

import Foundation
import Vapor

extension MCPToolError {
    /// Translates an `AbortError` into the MCP vocabulary, attributed to
    /// `tool`. Client-fixable 4xx failures become `invalidArguments`; anything
    /// else is a genuine server-side failure.
    ///
    /// `WebAssignmentError` is an `AbortError` too, and every one of its cases
    /// but `internalFailure` is a 4xx, so this one function maps it exactly as
    /// the `WebAssignmentError` overload it replaced did.
    static func from(_ error: any AbortError, tool: String) -> MCPToolError {
        if (400..<500).contains(Int(error.status.code)) {
            return .invalidArguments(tool: tool, detail: error.reason)
        }
        return .executionFailed(tool: tool, detail: error.reason)
    }
}
