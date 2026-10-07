// APIServer/MCP/Transport/MCPTool.swift
//
// The one tool abstraction behind both MCP surfaces (#2339). Conformers
// declare a typed Input/Output; the erasure decodes raw JSON-RPC `arguments`
// into Input before it calls `execute`, so a handler never touches untyped
// JSON. The `Surface` names the scope type, the context type and the per-tool
// traits, so a content tool cannot be registered on the admin surface or the
// reverse: the compiler keeps the two apart, not a second copy of this file.
// A tool conforms to `ContentTool` or `DiagnosticTool`, which fix the surface.

import Core
import Vapor

/// A single MCP tool on one surface.
protocol MCPTool: Sendable {
    associatedtype Surface: MCPSurface
    associatedtype Input: Decodable & Sendable
    associatedtype Output: Encodable & Sendable

    /// Stable tool name: the `tools/list` identifier and the registry key.
    static var name: String { get }
    /// Human-friendly display name surfaced as the tool's `title` in
    /// `tools/list`, so clients render "Get Server Info" rather than
    /// `get_server_info`. Defaults to a Title-Case derivation of `name`;
    /// override only when the derivation reads badly.
    static var title: String { get }
    /// Human-readable description surfaced in `tools/list`.
    static var description: String { get }
    /// JSON Schema (draft 2020-12) describing `Input`, surfaced in `tools/list`.
    static var inputSchema: JSONValue { get }
    /// JSON Schema (draft 2020-12) describing `Output`, surfaced as the tool's
    /// `outputSchema` so clients can validate the `structuredContent` it
    /// returns. Defaults to nil (no declared output schema).
    static var outputSchema: JSONValue? { get }
    /// Behavioural hints surfaced as the tool's `annotations` (read-only,
    /// destructive, idempotent…). Each surface supplies the default.
    static var annotations: MCPToolAnnotations? { get }
    /// Scopes the caller's token must carry before the dispatcher invokes this tool.
    static var requiredScopes: Set<Surface.Scope> { get }
    /// The surface's per-tool facts that its call hooks read.
    static var traits: Surface.ToolTraits { get }

    func execute(_ input: Input, _ context: Surface.Context) async throws -> Output
}

extension MCPTool {
    /// Title-Case derivation of the snake_case `name`
    /// ("get_server_info" → "Get Server Info").
    static var title: String {
        name.split(separator: "_").map { String($0).capitalized }.joined(separator: " ")
    }
    /// Tools declare no output schema unless they override this.
    static var outputSchema: JSONValue? { nil }
}

// MARK: - Type erasure

/// A type-erased tool of one surface, stored in the name-keyed registry.
/// `invoke` performs decode -> execute -> encode so the dispatcher only ever
/// handles `JSONValue`.
struct AnyMCPTool<Surface: MCPSurface>: Sendable {
    let name: String
    let title: String
    let description: String
    let inputSchema: JSONValue
    let outputSchema: JSONValue?
    let annotations: MCPToolAnnotations?
    let requiredScopes: Set<Surface.Scope>
    let traits: Surface.ToolTraits
    let invoke: @Sendable (_ arguments: JSONValue, _ context: Surface.Context) async throws -> JSONValue
}

// The shared tools/list entry encoding reads these fields (#1121).
extension AnyMCPTool: MCPListableTool {}

extension MCPTool {
    /// Erases this tool for storage in the registry.
    func erased() -> AnyMCPTool<Surface> {
        AnyMCPTool(
            name: Self.name,
            title: Self.title,
            description: Self.description,
            inputSchema: Self.inputSchema,
            outputSchema: Self.outputSchema,
            annotations: Self.annotations,
            requiredScopes: Self.requiredScopes,
            traits: Self.traits,
            invoke: { arguments, context in
                let input: Input
                do {
                    input = try arguments.decoded(as: Input.self)
                } catch {
                    throw MCPToolError.invalidArguments(detail: String(describing: error))
                }
                do {
                    let output = try await self.execute(input, context)
                    return try JSONValue(encoding: output)
                } catch let error as any AbortError where error.isClientRefusal {
                    // A refusal from a shared web path reaches the agent with
                    // its reason, whichever tool raised it (#1940, #2338). A 5xx
                    // is a server fault, not a refusal: it stays opaque to the
                    // agent, and the dispatcher logs it.
                    throw MCPToolError.from(error)
                }
            }
        )
    }
}
