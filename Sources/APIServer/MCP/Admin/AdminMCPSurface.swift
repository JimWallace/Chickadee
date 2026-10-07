// APIServer/MCP/Admin/AdminMCPSurface.swift
//
// The admin diagnostic surface's steps around a tool call (#2339): the admin
// role is re-checked before every tool that does not opt out (#1943), and each
// executed call gets one best-effort audit row. The surface is read-only, so
// nothing is refused for want of an audit row.

import Core

enum AdminMCPSurface: MCPSurface {
    typealias Scope = DiagnosticScope
    typealias Context = AdminToolContext
    typealias Admission = Void

    /// The per-tool facts the admin hooks read.
    struct ToolTraits: Sendable {
        /// See `DiagnosticTool.rechecksAdminRole`.
        let rechecksAdminRole: Bool
    }

    static let logLabel = "Admin MCP"

    static func admit(
        _ tool: AnyMCPTool<Self>, call: MCPToolCall, context: AdminToolContext
    ) async -> Result<Void, JSONRPCError> {
        .success(())
    }

    /// The admin re-check, run here once for every tool instead of as a line
    /// each tool must remember (#1943). A refusal is a tool error and is
    /// audited, as it was when each tool ran it itself.
    static func beforeInvoke(_ tool: AnyMCPTool<Self>, context: AdminToolContext) async throws {
        if tool.rechecksAdminRole {
            _ = try await context.requireAdminSubject()
        }
    }

    static func afterSuccess(call: MCPToolCall, context: AdminToolContext) async {}

    /// Best-effort audit: one row per executed call, attributed to the subject
    /// (suffixed -MCP) so agent reads are distinguishable from a human's web
    /// actions. Never logs arguments.
    static func finish(
        call: MCPToolCall, admission: Void, outcome: MCPToolOutcome, context: AdminToolContext
    ) async {
        var metadata = ["tool": call.name, "outcome": outcome.rawValue]
        if let agent = context.actingClientName {
            metadata["via_agent"] = agent
        }
        await AuditLogger.record(
            action: .adminMcpToolCalled,
            metadata: metadata,
            actorUsernameOverride: "\(context.subject)-MCP",
            on: context.request)
    }
}

extension AdminToolContext: MCPCallContext {}
