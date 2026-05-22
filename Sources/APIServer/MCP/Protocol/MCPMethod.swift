// APIServer/MCP/Protocol/MCPMethod.swift
//
// The JSON-RPC method names this server implements, plus the protocol
// revision it speaks.  `prompts/*` and any streaming methods are intentionally
// unimplemented in v1.
// https://modelcontextprotocol.io/specification/2025-11-25

import Foundation

/// The MCP protocol revision this server advertises in `initialize`.
enum MCPProtocol {
    static let version = "2025-11-25"
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
