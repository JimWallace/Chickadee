// APIServer/MCP/Tools/ContentTool.swift
//
// A tool on the content-authoring surface: an `MCPTool` over `ContentScope`
// and `ToolContext` (#2339). Conformers live in APIServer (they use Fluent +
// services); Core stays Vapor-free.

import Core

/// A single content-authoring tool.
protocol ContentTool: MCPTool where Surface == ContentMCPSurface {}

extension ContentTool {
    /// By default a tool is annotated read-only iff its only required scope is
    /// `content:read`; write tools override this to add destructive/idempotent
    /// hints.
    static var annotations: MCPToolAnnotations? {
        MCPToolAnnotations(readOnlyHint: requiredScopes == [.read])
    }
    /// The content surface's hooks read no per-tool traits.
    static var traits: MCPNoToolTraits { MCPNoToolTraits() }
}

/// A type-erased content tool, as the registry stores it.
typealias AnyContentTool = AnyMCPTool<ContentMCPSurface>

extension AnyMCPTool where Surface.ToolTraits == MCPNoToolTraits {
    init(
        name: String,
        title: String,
        description: String,
        inputSchema: JSONValue,
        outputSchema: JSONValue?,
        annotations: MCPToolAnnotations?,
        requiredScopes: Set<Surface.Scope>,
        invoke: @escaping @Sendable (_ arguments: JSONValue, _ context: Surface.Context) async throws -> JSONValue
    ) {
        self.init(
            name: name, title: title, description: description, inputSchema: inputSchema,
            outputSchema: outputSchema, annotations: annotations, requiredScopes: requiredScopes,
            traits: MCPNoToolTraits(), invoke: invoke)
    }
}

/// Name-keyed registry of content tools.
typealias ToolRegistry = MCPToolRegistry<AnyContentTool>
