// APIServer/MCP/Tools/ContentScope.swift
//
// OAuth scopes for the content surface. content:read and content:write reach
// course content only: nothing they grant touches student data, grades,
// enrolment, submissions, or administration. feedback:read and feedback:write
// are the one gated exception (docs/ai-assisted-feedback.md): they reach the
// written reasoning in an assignment whose course and assignment gates a
// person turned on, by pseudonymous handle, and nothing else.

/// An OAuth scope on the content surface.
enum ContentScope: String, CaseIterable, Sendable {
    case read = "content:read"
    case write = "content:write"
    case feedbackRead = "feedback:read"
    case feedbackWrite = "feedback:write"

    /// True for a scope that lets a tool change state. A tool that requires one
    /// gets a fail-closed audit row, and `MCP_MODE=read_only` never grants one.
    var isWrite: Bool {
        switch self {
        case .write, .feedbackWrite: return true
        case .read, .feedbackRead: return false
        }
    }
}
