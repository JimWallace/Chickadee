// APIServer/MCP/Transport/ContentMCPSurface.swift
//
// The content-authoring surface's steps around a tool call (#2339): a write
// tool's audit row is persisted before the tool runs, and the call is refused
// if it cannot be (fail closed); a successful write snapshots what it changed;
// the outcome is stamped on the row. A read tool gets one best-effort row.

import Core

enum ContentMCPSurface: MCPSurface {
    typealias Scope = ContentScope
    typealias Context = ToolContext
    typealias ToolTraits = MCPNoToolTraits

    /// The audit state `admit` hands on to `finish`.
    struct Admission {
        /// The call's target, resolved from the arguments up front so a
        /// failing call is still attributed to what it acted on. Only the
        /// identifier is captured — never the argument values.
        let target: MCPAuditTarget?
        /// The row persisted before a write tool ran; nil for a read tool.
        let writeRow: APIAuditLogEntry?
    }

    static let logLabel = "MCP"

    /// Fail closed for writes: a state-changing tool must not run unless its
    /// audit record is durably persisted first. Read tools stay best-effort
    /// (a read that can't be audited is not blocked).
    static func admit(
        _ tool: AnyMCPTool<Self>, call: MCPToolCall, context: ToolContext
    ) async -> Result<Admission, JSONRPCError> {
        let target = MCPAuditTarget(arguments: call.arguments)
        guard tool.requiredScopes.contains(.write) else {
            return .success(Admission(target: target, writeRow: nil))
        }
        guard let row = await recordToolCall(name: call.name, context: context, target: target) else {
            return .failure(
                .internalError("Refusing to run \(call.name): its audit record could not be persisted."))
        }
        return .success(Admission(target: target, writeRow: row))
    }

    static func beforeInvoke(_ tool: AnyMCPTool<Self>, context: ToolContext) async throws {}

    /// Snapshots the content of any setup this call resolved for write, now
    /// that the edit has persisted. Only on success: a failed call changed
    /// nothing worth a version. Best-effort inside — history must never be the
    /// reason an instructor's edit fails.
    static func afterSuccess(call: MCPToolCall, context: ToolContext) async {
        await context.finishContentWrites(tool: call.name)
    }

    static func finish(
        call: MCPToolCall, admission: Admission, outcome: MCPToolOutcome, context: ToolContext
    ) async {
        if let row = admission.writeRow {
            // Stamp the outcome onto the row already persisted before the write.
            await AuditLogger.updateMetadata(row, merging: ["outcome": outcome.rawValue], on: context.request)
        } else {
            // Read tool: one best-effort row carrying the outcome.
            await recordToolCall(name: call.name, context: context, target: admission.target, outcome: outcome)
        }
    }

    /// Records an `mcp.tool_called` audit entry and returns the persisted row
    /// (nil if the write failed). The actor is the token subject suffixed with
    /// `-MCP` (e.g. `jsmith-MCP`) so agent-made changes are tracked separately
    /// from the human's own web actions in the admin audit log; the acting agent
    /// is in `via_agent` when present. The target resource (assignment public ID
    /// or course code) and, when known, the outcome are recorded. Never logs
    /// tool arguments.
    @discardableResult
    static func recordToolCall(
        name: String, context: ToolContext,
        target: MCPAuditTarget? = nil, outcome: MCPToolOutcome? = nil
    ) async -> APIAuditLogEntry? {
        var metadata = ["tool": name]
        if let agent = context.actingClientName {
            metadata["via_agent"] = agent
        }
        if let outcome {
            metadata["outcome"] = outcome.rawValue
        }
        return await AuditLogger.recordReturning(
            action: .mcpToolCalled,
            targetType: target?.type,
            targetID: target?.id,
            metadata: metadata,
            actorUsernameOverride: "\(context.subject)-MCP",
            on: context.request)
    }
}

extension ToolContext: MCPCallContext {}
