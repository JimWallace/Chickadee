// APIServer/Services/CourseSectionError.swift
//
// Why `CourseSectionService` refused a course section (#2769). The web routes
// map it to `AppError.invalidParameter(name: field, reason:
// description)` and the MCP tools to `MCPToolError.invalidArguments(detail:
// description)`, so both surfaces give the same reason.

import Core

enum CourseSectionError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyName
    /// The default type is not an `AssignmentType`.
    case unknownAssignmentType(String)

    /// The input field the error is about.
    var field: String {
        switch self {
        case .emptyName: return "name"
        case .unknownAssignmentType: return "defaultAssignmentType"
        }
    }

    var description: String {
        switch self {
        case .emptyName:
            return "Section name must not be empty."
        case .unknownAssignmentType:
            // The same list `MCPEnumProse.parse` names, from one source.
            return "defaultAssignmentType must be one of: \(MCPEnumProse<AssignmentType>.oneOfList), "
                + "or an empty string for no default."
        }
    }
}
