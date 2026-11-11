// APIServer/Services/CourseSectionError.swift
//
// Why `CourseSectionService` refused a course section (#2769). The web routes
// map it to `AppError.invalidParameter(name: field, reason:
// description)` and the MCP tools to `MCPToolError.invalidArguments(detail:
// description)`, so both surfaces give the same reason.

enum CourseSectionError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyName

    /// The input field the error is about.
    var field: String {
        switch self {
        case .emptyName: return "name"
        }
    }

    var description: String {
        switch self {
        case .emptyName: return "Section name must not be empty."
        }
    }
}
