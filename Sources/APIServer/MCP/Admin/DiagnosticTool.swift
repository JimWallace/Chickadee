// APIServer/MCP/Admin/DiagnosticTool.swift
//
// The tool abstraction for the admin diagnostic MCP surface.  Parallel to
// `ContentTool` but over `DiagnosticScope` + `AdminToolContext`: a deliberate
// thin duplication rather than generalizing the shipped content stack, so the
// two surfaces stay isolated and a change to one can't destabilize the other
// (docs/admin-mcp.md §3.4).  Every diagnostic tool is read-only.

import Core

/// A single admin diagnostic tool.
protocol DiagnosticTool: Sendable {
    associatedtype Input: Decodable & Sendable
    associatedtype Output: Encodable & Sendable

    /// Stable tool name: the `tools/list` identifier and the registry key.
    static var name: String { get }
    /// Human-friendly display name (defaults to a Title-Case derivation of `name`).
    static var title: String { get }
    /// Human-readable description surfaced in `tools/list`.
    static var description: String { get }
    /// JSON Schema (draft 2020-12) describing `Input`, surfaced in `tools/list`.
    static var inputSchema: JSONValue { get }
    /// JSON Schema (draft 2020-12) describing `Output` (defaults to nil).
    static var outputSchema: JSONValue? { get }
    /// Behavioural hints surfaced as the tool's `annotations` (defaults to
    /// read-only, since the whole surface is read-only).
    static var annotations: MCPToolAnnotations? { get }
    /// Scopes the caller's token must carry (defaults to `diagnostics:read`).
    static var requiredScopes: Set<DiagnosticScope> { get }

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output
}

extension DiagnosticTool {
    static var title: String {
        name.split(separator: "_").map { String($0).capitalized }.joined(separator: " ")
    }
    static var outputSchema: JSONValue? { nil }
    static var annotations: MCPToolAnnotations? { MCPToolAnnotations(readOnlyHint: true) }
    /// The admin surface is read-only, so every tool requires exactly
    /// `diagnostics:read` unless it overrides this.
    static var requiredScopes: Set<DiagnosticScope> { [.read] }
}

// MARK: - Type erasure

/// A type-erased `DiagnosticTool` stored in the name-keyed registry.  `invoke`
/// performs decode -> execute -> encode so the dispatcher only ever handles
/// `JSONValue`.
struct AnyDiagnosticTool: Sendable {
    let name: String
    let title: String
    let description: String
    let inputSchema: JSONValue
    let outputSchema: JSONValue?
    let annotations: MCPToolAnnotations?
    let requiredScopes: Set<DiagnosticScope>
    let invoke: @Sendable (_ arguments: JSONValue, _ context: AdminToolContext) async throws -> JSONValue
}

// The shared tools/list entry encoding reads these fields (#1121).
extension AnyDiagnosticTool: MCPListableTool {}

extension DiagnosticTool {
    /// Erases this tool for storage in the registry.
    func erased() -> AnyDiagnosticTool {
        AnyDiagnosticTool(
            name: Self.name,
            title: Self.title,
            description: Self.description,
            inputSchema: Self.inputSchema,
            outputSchema: Self.outputSchema,
            annotations: Self.annotations,
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

/// Name-keyed registry of admin diagnostic tools.
struct DiagnosticToolRegistry: Sendable {
    private let toolsByName: [String: AnyDiagnosticTool]

    init(_ tools: [AnyDiagnosticTool]) {
        toolsByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { existing, _ in existing })
    }

    /// All registered tools, sorted by name for stable `tools/list` output.
    var all: [AnyDiagnosticTool] {
        toolsByName.values.sorted { $0.name < $1.name }
    }

    func tool(named name: String) -> AnyDiagnosticTool? {
        toolsByName[name]
    }
}
