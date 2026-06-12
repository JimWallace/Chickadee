// APIServer/MCP/Tools/ContentScope.swift
//
// OAuth scopes for content authoring.  Deliberately narrow: a token carries
// content:read and/or content:write and nothing here grants access to student
// data, grades, enrolment, submissions, or administration.

/// A content-authoring OAuth scope.
enum ContentScope: String, CaseIterable, Sendable {
    case read = "content:read"
    case write = "content:write"
}
