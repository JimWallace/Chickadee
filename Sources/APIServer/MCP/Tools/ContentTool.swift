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
    /// JSON Schema (draft 2020-12) describing `Output`, surfaced as the tool's
    /// `outputSchema` so clients can validate the `structuredContent` it
    /// returns.  Defaults to nil (no declared output schema).
    static var outputSchema: JSONValue? { get }
    /// Behavioural hints surfaced as the tool's `annotations` (read-only,
    /// destructive, idempotent…).  Defaults to a read-only hint inferred from
    /// `requiredScopes`.
    static var annotations: MCPToolAnnotations? { get }
    /// Scopes the caller's token must carry before the dispatcher invokes this tool.
    static var requiredScopes: Set<ContentScope> { get }

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output
}

/// Behavioural hints for a tool, surfaced in `tools/list` under `annotations`.
/// All fields are optional; nil fields are omitted from the wire.  These are
/// hints, not a security boundary — enforcement still lives in `requiredScopes`
/// and the per-tool authorization checks.
/// https://modelcontextprotocol.io/specification/2025-11-25/server/tools
struct MCPToolAnnotations: Encodable, Sendable {
    /// Human-friendly display title for the tool.
    var title: String?
    /// The tool does not modify its environment.
    var readOnlyHint: Bool?
    /// The tool may perform destructive updates (meaningful only when not read-only).
    var destructiveHint: Bool?
    /// Repeated calls with the same arguments have no additional effect beyond the first.
    var idempotentHint: Bool?
    /// The tool interacts with an open world of external entities.
    var openWorldHint: Bool?

    init(
        title: String? = nil,
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }
}

extension ContentTool {
    /// Tools declare no output schema unless they override this.
    static var outputSchema: JSONValue? { nil }
    /// By default a tool is annotated read-only iff its only required scope is
    /// `content:read`; write tools override this to add destructive/idempotent
    /// hints.
    static var annotations: MCPToolAnnotations? {
        MCPToolAnnotations(readOnlyHint: requiredScopes == [.read])
    }
}

// MARK: - Errors

/// Errors raised while resolving or invoking a tool.  Mapped to JSON-RPC errors
/// by the dispatcher.
enum MCPToolError: Error, Sendable, Equatable {
    case unknownTool(String)
    case invalidArguments(tool: String, detail: String)
    /// The authenticated subject is not permitted to act on the targeted
    /// resource — e.g. the MCP account is not enrolled in the target course.
    case notAuthorized(tool: String, detail: String)
    /// The tool's arguments were valid and authorized, but the operation
    /// failed while executing (e.g. a file copy or a downstream save). Surfaced
    /// to the model so it can retry or report rather than seeing an opaque
    /// protocol-level internal error.
    case executionFailed(tool: String, detail: String)
}

// MARK: - Type erasure

/// A type-erased `ContentTool` stored in the name-keyed registry.  `invoke`
/// performs decode -> execute -> encode so the dispatcher only ever handles
/// `JSONValue`.
struct AnyContentTool: Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue
    let outputSchema: JSONValue?
    let annotations: MCPToolAnnotations?
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
