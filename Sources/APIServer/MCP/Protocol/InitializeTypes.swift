// APIServer/MCP/Protocol/InitializeTypes.swift
//
// Result types for the MCP `initialize` handshake.  Capabilities advertise
// only what v1 implements — tools and resources, both without list-change
// notifications, since there is no server-initiated streaming yet.
// https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle

/// The result returned from an `initialize` request.
struct MCPInitializeResult: Encodable, Sendable {
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
    let serverInfo: MCPServerInfo
}

/// Capabilities this server advertises at initialization.  `listChanged` is
/// false because v1 does not push list-change notifications (no streaming).
struct MCPServerCapabilities: Encodable, Sendable {
    let tools: ListChanged
    let resources: ListChanged

    struct ListChanged: Encodable, Sendable {
        let listChanged: Bool
    }

    /// The capability set advertised by v1: tools + resources, no list-change
    /// notifications.
    static let v1 = MCPServerCapabilities(
        tools: ListChanged(listChanged: false),
        resources: ListChanged(listChanged: false)
    )
}

/// Identifies this server to the client in the `initialize` result.
struct MCPServerInfo: Encodable, Sendable {
    let name: String
    let version: String
}
