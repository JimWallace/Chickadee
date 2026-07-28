// APIServer/MCP/Protocol/MCPRequestMeta.swift
//
// The per-request metadata of the modern (2026-07-28) protocol revision.
// Where the legacy revisions established protocol version, client identity,
// and capabilities once at `initialize`, the modern revision carries them in a
// `_meta` object on EVERY request — which is what lets a server answer each
// request without inferring anything from the connection.
//
// This file is the pure/parsing half: the reserved key names, the era a
// request is speaking, and extraction of the fields from `params._meta`.  The
// HTTP-level rules (mirrored headers, status codes) live in
// Transport/MCPModernTransport.swift.
// https://modelcontextprotocol.io/specification/2026-07-28/basic#meta

import Core

/// Reserved `_meta` keys defined by the MCP specification.  The
/// `io.modelcontextprotocol/` prefix is reserved for the spec, so these names
/// are stable and must be matched exactly.
enum MCPMetaKey {
    static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
    static let clientInfo = "io.modelcontextprotocol/clientInfo"
    static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
    static let logLevel = "io.modelcontextprotocol/logLevel"
    static let serverInfo = "io.modelcontextprotocol/serverInfo"
}

/// Which protocol era a single request is speaking.  Determined per request —
/// never inferred from the connection — so one endpoint serves both.
enum MCPEra: Sendable {
    /// 2025-11-25 and earlier: the `initialize` handshake established the
    /// session, and results carry no `resultType`.
    case legacy
    /// 2026-07-28 and later: version/identity/capabilities in each request's
    /// `_meta`, results carry `resultType` and the server's own `_meta`.
    case modern
}

/// The modern per-request `_meta` fields this server reads.
struct MCPRequestMeta: Sendable {
    /// `io.modelcontextprotocol/protocolVersion` — REQUIRED on a modern
    /// request; its presence is what marks the request as modern.
    let protocolVersion: String?
    /// True when `io.modelcontextprotocol/clientCapabilities` is present.
    /// REQUIRED on a modern request (the value itself is unused: this server
    /// needs no client capability — it implements no sampling, roots, or
    /// elicitation — so it can never raise MissingRequiredClientCapability).
    let hasClientCapabilities: Bool
    /// `io.modelcontextprotocol/clientInfo` name/version, when supplied.
    /// Self-reported and never trusted for anything but logging.
    let clientName: String?
    let clientVersion: String?

    /// True when this request declares a protocol version in `_meta` — the
    /// signal that it intends the modern protocol, whatever the version's
    /// value (an unsupported one is rejected with UnsupportedProtocolVersion,
    /// not treated as legacy).
    var declaresModernProtocol: Bool { protocolVersion != nil }

    /// Reads the modern fields out of a request's `params._meta`.  Always
    /// returns a value: a request with no `_meta` at all simply has every
    /// field empty, which reads as legacy.
    static func extract(fromParams params: JSONValue?) -> MCPRequestMeta {
        guard case .object(let paramFields)? = params,
            case .object(let meta)? = paramFields["_meta"]
        else {
            return MCPRequestMeta(
                protocolVersion: nil, hasClientCapabilities: false,
                clientName: nil, clientVersion: nil)
        }
        var version: String?
        if case .string(let value)? = meta[MCPMetaKey.protocolVersion] {
            version = value
        }
        var name: String?
        var clientVersion: String?
        if case .object(let info)? = meta[MCPMetaKey.clientInfo] {
            if case .string(let value)? = info["name"] { name = value }
            if case .string(let value)? = info["version"] { clientVersion = value }
        }
        return MCPRequestMeta(
            protocolVersion: version,
            hasClientCapabilities: meta[MCPMetaKey.clientCapabilities] != nil,
            clientName: name,
            clientVersion: clientVersion)
    }
}
