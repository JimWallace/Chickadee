// APIServer/Services/CourseSectionError.swift
//
// Why `CourseSectionService` refused a course section (#2769). The web routes
// map it to `WebAssignmentError.invalidParameter(name: field, reason:
// description)` and the MCP tools to `MCPToolError.invalidArguments(detail:
// description)`, so both surfaces give the same reason.

import Core

enum CourseSectionError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyName
    /// The grading mode is not a `GradingMode`.
    case unknownGradingMode(String)

    /// The input field the error is about.
    var field: String {
        switch self {
        case .emptyName: return "name"
        case .unknownGradingMode: return "defaultGradingMode"
        }
    }

    var description: String {
        switch self {
        case .emptyName:
            return "Section name must not be empty."
        case .unknownGradingMode:
            // The same list `MCPEnumProse.parse` names, from one source.
            return "defaultGradingMode must be one of: \(MCPEnumProse<GradingMode>.oneOfList)."
        }
    }
}
