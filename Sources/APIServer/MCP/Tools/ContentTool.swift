// APIServer/MCP/Tools/ContentTool.swift
//
// The tool abstraction surfaced over MCP `tools/list` and `tools/call`.
// Conformers declare a typed Input/Output; the dispatcher decodes raw JSON-RPC
// `arguments` into Input before calling `execute`, so handlers never touch
// untyped JSON.  Conformers live in APIServer (they use Fluent + services);
// Core stays Vapor-free.

import Core

/// A single content-authoring tool.
protocol ContentTool: Sendable {
    associatedtype Input: Decodable & Sendable
    associatedtype Output: Encodable & Sendable

    /// Stable tool name: the `tools/list` identifier and the registry key.
    static var name: String { get }
    /// Human-readable description surfaced in `tools/list`.
    static var description: String { get }
    /// JSON Schema (draft 2020-12) describing `Input`, surfaced in `tools/list`.
    static var inputSchema: JSONValue { get }
    /// Scopes the caller's token must carry before the dispatcher invokes this tool.
    static var requiredScopes: Set<ContentScope> { get }

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output
}

// MARK: - Errors

/// Errors raised while resolving or invoking a tool.  Mapped to JSON-RPC errors
/// by the dispatcher.
enum MCPToolError: Error, Sendable, Equatable {
    case unknownTool(String)
    case invalidArguments(tool: String, detail: String)
}

// MARK: - Type erasure

/// A type-erased `ContentTool` stored in the name-keyed registry.  `invoke`
/// performs decode -> execute -> encode so the dispatcher only ever handles
/// `JSONValue`.
struct AnyContentTool: Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue
    let requiredScopes: Set<ContentScope>
    let invoke: @Sendable (_ arguments: JSONValue, _ context: ToolContext) async throws -> JSONValue
}

extension ContentTool {
    /// Erases this tool for storage in the registry.
    func erased() -> AnyContentTool {
        AnyContentTool(
            name: Self.name,
            description: Self.description,
            inputSchema: Self.inputSchema,
            requiredScopes: Self.requiredScopes,
            invoke: { arguments, context in
                let input: Input
                do {
                    input = try arguments.decoded(as: Input.self)
                } catch {
                    throw MCPToolError.invalidArguments(tool: Self.name, detail: String(describing: error))
                }
                let output = try await self.execute(input, context)
                return try JSONValue(encoding: output)
            }
        )
    }
}

// MARK: - Registry

/// Name-keyed registry of content tools.
struct ToolRegistry: Sendable {
    private let toolsByName: [String: AnyContentTool]

    init(_ tools: [AnyContentTool]) {
        toolsByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { existing, _ in existing })
    }

    /// All registered tools, sorted by name for stable `tools/list` output.
    var all: [AnyContentTool] {
        toolsByName.values.sorted { $0.name < $1.name }
    }

    func tool(named name: String) -> AnyContentTool? {
        toolsByName[name]
    }
}
