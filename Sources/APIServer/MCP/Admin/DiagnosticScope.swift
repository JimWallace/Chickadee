// APIServer/MCP/Admin/DiagnosticScope.swift
//
// OAuth scope for the admin diagnostic MCP surface.  Deliberately separate from
// `ContentScope`: this surface is deployment-wide and read-only, and nothing
// here grants content authoring or any write access.  Keeping it a distinct type
// (with its own token audience, §3.3 of docs/admin-mcp.md) means a content token
// can never satisfy an admin tool's scope check, and vice versa.

/// An admin-diagnostics OAuth scope.  Read-only by construction — there is no
/// write case, so the surface cannot express mutation.
enum DiagnosticScope: String, CaseIterable, Sendable {
    case read = "diagnostics:read"
}
