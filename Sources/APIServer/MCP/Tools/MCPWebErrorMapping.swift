// APIServer/MCP/Tools/MCPWebErrorMapping.swift
//
// Several write tools reuse the server-authoritative web edit paths, which
// raise `WebAssignmentError` (an HTTP-shaped error) or a Vapor `Abort`. Over
// MCP those need to become `MCPToolError` so the dispatcher surfaces a clean
// JSON-RPC error to the agent rather than an opaque internal failure.
// Validation-class failures (bad input the agent can fix) map to
// `invalidArguments`; genuine server-side failures map to `executionFailed`.
//
// One policy everywhere (#2338): a client refusal (4xx) reaches the agent
// with its reason; a server fault (5xx) is left alone, so it stays opaque to
// the agent and the dispatcher logs it. Both erasures apply it to every tool.
// The explicit catches in some tools remain because tests call `execute`
// directly (#1940); they use the same `isClientRefusal` test.

import Foundation
import Vapor

extension MCPToolError {
    /// Translates an `AbortError` into the MCP vocabulary. Client-fixable 4xx
    /// failures become `invalidArguments`; anything else is a genuine
    /// server-side failure. Callers map only a client refusal
    /// (`isClientRefusal`) and let a server fault propagate.
    ///
    /// `WebAssignmentError` is an `AbortError` too, and every one of its cases
    /// but `internalFailure` is a 4xx, so this one function maps it exactly as
    /// the `WebAssignmentError` overload it replaced did.
    static func from(_ error: any AbortError) -> MCPToolError {
        if (400..<500).contains(Int(error.status.code)) {
            return .invalidArguments(detail: error.reason)
        }
        return .executionFailed(detail: error.reason)
    }
}

extension AbortError {
    /// A 4xx: a refusal the agent can act on, not a server fault.
    var isClientRefusal: Bool {
        (400..<500).contains(Int(status.code))
    }
}
