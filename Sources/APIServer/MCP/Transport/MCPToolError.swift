// APIServer/MCP/Transport/MCPToolError.swift
//
// The errors a tool raises, shared by both MCP surfaces. The shared tools/call
// code reports them to the agent inside the result (`isError: true`).

/// Errors raised while resolving or invoking a tool.  Mapped to JSON-RPC errors
/// by the dispatcher.
enum MCPToolError: Error, Sendable, Equatable {
    case unknownTool(String)
    case invalidArguments(detail: String)
    /// The authenticated subject is not permitted to act on the targeted
    /// resource — e.g. the MCP account is not enrolled in the target course.
    case notAuthorized(detail: String)
    /// The tool's arguments were valid and authorized, but the operation
    /// failed while executing (e.g. a file copy or a downstream save). Surfaced
    /// to the model so it can retry or report rather than seeing an opaque
    /// protocol-level internal error.
    case executionFailed(detail: String)
}

/// Classification of a tool call's outcome, recorded in the audit metadata so a
/// reviewer can see whether a call succeeded or failed without the tool ever
/// logging its arguments.
enum MCPToolOutcome: String, Sendable {
    case success
    case invalidArguments = "invalid_arguments"
    case notAuthorized = "not_authorized"
    case executionFailed = "execution_failed"
    case failed

    init(_ error: MCPToolError) {
        switch error {
        case .unknownTool: self = .failed
        case .invalidArguments: self = .invalidArguments
        case .notAuthorized: self = .notAuthorized
        case .executionFailed: self = .executionFailed
        }
    }
}
