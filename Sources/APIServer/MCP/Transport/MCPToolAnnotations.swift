// APIServer/MCP/Transport/MCPToolAnnotations.swift
//
// The `annotations` of a `tools/list` entry, shared by both MCP surfaces.

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
