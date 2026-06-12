// APIServer/MCP/Protocol/MCPMethod.swift
//
// The JSON-RPC method names this server implements, plus the protocol
// revision it speaks.  `prompts/*` and any streaming methods are intentionally
// unimplemented in v1.
// https://modelcontextprotocol.io/specification/2025-11-25

/// The MCP protocol revision this server advertises in `initialize`.
enum MCPProtocol {
    static let version = "2025-11-25"

    /// Revisions accepted in the `MCP-Protocol-Version` transport header.
    /// 2025-06-18 is wire-compatible with everything this server implements
    /// (single-message POSTs, the same tools/resources shapes).  2025-03-26 is
    /// deliberately absent: that revision allows JSON-RPC batching, which this
    /// transport does not parse — and clients of that era predate the header
    /// anyway (an absent header is accepted, see MCPRoutes).
    static let supportedVersions: Set<String> = [version, "2025-06-18"]
}

/// MCP JSON-RPC methods recognised by the dispatcher.  Unknown methods yield a
/// JSON-RPC `methodNotFound` (-32601) error.
enum MCPMethod: String, Sendable {
    case initialize
    case initialized = "notifications/initialized"
    case ping
    case toolsList = "tools/list"
    case toolsCall = "tools/call"
    case resourcesList = "resources/list"
    case resourcesRead = "resources/read"
}
