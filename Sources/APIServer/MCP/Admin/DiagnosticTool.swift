// APIServer/MCP/Admin/DiagnosticTool.swift
//
// A tool on the admin diagnostic surface: an `MCPTool` over `DiagnosticScope`
// and `AdminToolContext` (#2339). The distinct scope and context types keep it
// apart from the content surface (docs/admin-mcp.md §3.4); the tool protocol,
// the erasure and the tools/call code are shared. Every diagnostic tool is
// read-only.

import Core

/// A single admin diagnostic tool.
protocol DiagnosticTool: MCPTool where Surface == AdminMCPSurface {
    /// Whether the dispatcher confirms the token subject is an admin before it
    /// runs the tool (defaults to true). The re-check used to be a line every
    /// tool had to remember, and a tool that forgot it was protected only by
    /// the bearer layer (#1943). Opting out is a stated decision.
    static var rechecksAdminRole: Bool { get }
}

extension DiagnosticTool {
    /// The whole surface is read-only.
    static var annotations: MCPToolAnnotations? { MCPToolAnnotations(readOnlyHint: true) }
    /// The admin surface is read-only, so every tool requires exactly
    /// `diagnostics:read` unless it overrides this.
    static var requiredScopes: Set<DiagnosticScope> { [.read] }
    static var rechecksAdminRole: Bool { true }
    static var traits: AdminMCPSurface.ToolTraits {
        AdminMCPSurface.ToolTraits(rechecksAdminRole: rechecksAdminRole)
    }
}

/// A type-erased admin diagnostic tool, as the registry stores it.
typealias AnyDiagnosticTool = AnyMCPTool<AdminMCPSurface>

extension AnyMCPTool where Surface == AdminMCPSurface {
    init(
        name: String,
        title: String,
        description: String,
        inputSchema: JSONValue,
        outputSchema: JSONValue?,
        annotations: MCPToolAnnotations?,
        requiredScopes: Set<DiagnosticScope>,
        rechecksAdminRole: Bool,
        invoke: @escaping @Sendable (_ arguments: JSONValue, _ context: AdminToolContext) async throws -> JSONValue
    ) {
        self.init(
            name: name, title: title, description: description, inputSchema: inputSchema,
            outputSchema: outputSchema, annotations: annotations, requiredScopes: requiredScopes,
            traits: AdminMCPSurface.ToolTraits(rechecksAdminRole: rechecksAdminRole), invoke: invoke)
    }

    /// Whether the dispatcher re-checks the admin role before this tool runs.
    var rechecksAdminRole: Bool { traits.rechecksAdminRole }
}

/// Name-keyed registry of admin diagnostic tools.
typealias DiagnosticToolRegistry = MCPToolRegistry<AnyDiagnosticTool>
