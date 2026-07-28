// APIServer/MCP/Protocol/MCPMethod.swift
//
// The JSON-RPC method names this server implements, plus the protocol
// revisions it speaks.  `prompts/*` is intentionally unimplemented.
//
// This server is DUAL-ERA (#1218): it serves both the modern, per-request
// revision (2026-07-28 — no handshake, protocol version and client identity
// travel in each request's `_meta`) and the legacy handshake revisions
// (2025-11-25 / 2025-06-18 — `initialize` establishes the connection).  The
// spec explicitly blesses serving both on one endpoint, selecting behaviour
// from how the client opens.
// https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning

/// The MCP protocol revisions this server speaks.
enum MCPProtocol {
    /// The default answered to a legacy `initialize` whose requested revision
    /// this server does not speak.
    static let version = "2025-11-25"

    /// The modern, handshake-free revision.  Selected per request by the
    /// presence of `io.modelcontextprotocol/protocolVersion` in `_meta`.
    static let modernVersion = "2026-07-28"

    /// Revisions negotiable through the legacy `initialize` handshake.
    /// 2025-06-18 is wire-compatible with everything this server implements
    /// (single-message POSTs, the same tools/resources shapes).  2025-03-26 is
    /// deliberately absent: that revision allows JSON-RPC batching, which this
    /// transport does not parse — and clients of that era predate the header
    /// anyway (an absent header is accepted, see MCPRoutes).  The modern
    /// revision is NOT here: a legacy client cannot speak it, so `initialize`
    /// never negotiates up into it.
    static let legacyVersions: Set<String> = [version, "2025-06-18"]

    /// Every revision accepted in the `MCP-Protocol-Version` transport header.
    static let supportedVersions: Set<String> = legacyVersions.union([modernVersion])

    /// `supportedVersions` newest-first, as advertised in `server/discover`
    /// and in the `data.supported` list of an `UnsupportedProtocolVersionError`
    /// (the client picks one and retries, so the order is the preference).
    static let advertisedVersions: [String] = [modernVersion, version, "2025-06-18"]
}

/// MCP JSON-RPC methods recognised by the dispatcher.  Unknown methods yield a
/// JSON-RPC `methodNotFound` (-32601) error.
enum MCPMethod: String, Sendable {
    case initialize
    case initialized = "notifications/initialized"
    case ping
    /// Modern discovery: supported versions, capabilities, and instructions in
    /// one call.  Servers MUST implement it (2026-07-28 §Discovery); it
    /// replaces the `initialize` handshake as the way a client learns what
    /// this server is.
    case serverDiscover = "server/discover"
    case toolsList = "tools/list"
    case toolsCall = "tools/call"
    case resourcesList = "resources/list"
    case resourcesRead = "resources/read"
}
