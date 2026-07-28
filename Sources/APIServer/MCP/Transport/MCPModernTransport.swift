// APIServer/MCP/Transport/MCPModernTransport.swift
//
// The HTTP-level half of the modern (2026-07-28) revision, shared by the
// content transport (`MCPRoutes`) and the admin diagnostic transport
// (`AdminMCPRoutes`) so the two can never drift on wire behaviour.
//
// Two things are new at the transport for modern requests:
//
//  1. MIRRORED HEADERS.  `MCP-Protocol-Version`, `Mcp-Method`, and (for
//     tools/call, resources/read, prompts/get) `Mcp-Name` repeat values from
//     the body so a load balancer can route without parsing it.  A server that
//     reads the body MUST verify they agree — otherwise an intermediary could
//     route on one value while this server executes another — and reject a
//     mismatch with 400 + HeaderMismatch (-32020).
//
//  2. STATUS CODES.  Modern errors are HTTP-visible: unsupported version,
//     header mismatch, and malformed `_meta` are 400; an unimplemented method
//     is 404 (which is how a modern client tells "this server doesn't do that"
//     from a legacy server that has no modern endpoint at all).
//
// Legacy requests are untouched by all of it: they are detected by the absence
// of `io.modelcontextprotocol/protocolVersion` in `_meta` and keep the
// pre-existing behaviour exactly.
// https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http

import Core
import Vapor

/// Mirrored request headers defined by the Streamable HTTP binding.
enum MCPHeader {
    static let protocolVersion = "MCP-Protocol-Version"
    static let method = "Mcp-Method"
    static let name = "Mcp-Name"
}

/// Resolves which era a POST is speaking — the spec's own rule: "a request
/// carrying modern per-request `_meta` is served statelessly according to this
/// revision; an `initialize` request selects legacy semantics."
///
/// A request whose `MCP-Protocol-Version` header names the modern revision
/// also counts as modern intent even if its `_meta` is absent, so a modern
/// client that omits the required fields gets the malformed-request error it
/// deserves rather than being silently served legacy semantics.
func mcpEra(of meta: MCPRequestMeta, request: Request) -> MCPEra {
    if meta.declaresModernProtocol { return .modern }
    if request.headers.first(name: MCPHeader.protocolVersion) == MCPProtocol.modernVersion {
        return .modern
    }
    return .legacy
}

/// Validates a modern request at the transport, returning the error to reject
/// it with, or nil when it is well-formed. Applies only to modern requests
/// (not notifications: this revision defines no client-to-server notification
/// over Streamable HTTP and leaves their header rules unspecified).
func mcpModernTransportRejection(
    request: Request, rpc: JSONRPCRequest, meta: MCPRequestMeta, era: MCPEra
) -> JSONRPCError? {
    guard era == .modern else { return nil }
    guard let declared = meta.protocolVersion else {
        return .invalidParams(
            "\(MCPMetaKey.protocolVersion) is required in _meta on every request of protocol "
                + "\(MCPProtocol.modernVersion).")
    }

    // The version must be one this server implements; the error carries the
    // supported list so the client retries rather than failing.
    guard MCPProtocol.supportedVersions.contains(declared) else {
        return .unsupportedProtocolVersion(requested: declared)
    }
    // `clientCapabilities` is required on every modern request; a request
    // missing a required `_meta` field is malformed.
    guard meta.hasClientCapabilities else {
        return .invalidParams(
            "\(MCPMetaKey.clientCapabilities) is required on every request of protocol \(declared).")
    }

    // Header/body agreement.
    guard let headerVersion = request.headers.first(name: MCPHeader.protocolVersion) else {
        return .headerMismatch("the \(MCPHeader.protocolVersion) header is required.")
    }
    guard headerVersion == declared else {
        return .headerMismatch(
            "\(MCPHeader.protocolVersion) header value \"\(headerVersion)\" does not match the "
                + "request body value \"\(declared)\".")
    }
    guard let headerMethod = request.headers.first(name: MCPHeader.method) else {
        return .headerMismatch("the \(MCPHeader.method) header is required.")
    }
    guard headerMethod == rpc.method else {
        return .headerMismatch(
            "\(MCPHeader.method) header value \"\(headerMethod)\" does not match the request body "
                + "method \"\(rpc.method)\".")
    }
    // `Mcp-Name` mirrors params.name (tools/call, prompts/get) or params.uri
    // (resources/read). Required only when the body actually carries the
    // source value — a body missing it is malformed on its own terms, and the
    // method handler produces the better error.
    if let expected = mcpNameSourceValue(rpc) {
        guard let raw = request.headers.first(name: MCPHeader.name) else {
            return .headerMismatch("the \(MCPHeader.name) header is required for \(rpc.method).")
        }
        guard let decoded = mcpDecodedHeaderValue(raw) else {
            return .headerMismatch("the \(MCPHeader.name) header value is not valid base64.")
        }
        guard decoded == expected else {
            return .headerMismatch(
                "\(MCPHeader.name) header value \"\(decoded)\" does not match the request body "
                    + "value \"\(expected)\".")
        }
    }
    return nil
}

/// The body value `Mcp-Name` must mirror for this method, or nil when the
/// method does not carry one.
func mcpNameSourceValue(_ rpc: JSONRPCRequest) -> String? {
    guard case .object(let params)? = rpc.params else { return nil }
    switch rpc.method {
    case MCPMethod.toolsCall.rawValue, "prompts/get":
        if case .string(let name)? = params["name"] { return name }
    case MCPMethod.resourcesRead.rawValue:
        if case .string(let uri)? = params["uri"] { return uri }
    default:
        return nil
    }
    return nil
}

/// Decodes a mirrored header value, unwrapping the `=?base64?…?=` sentinel the
/// spec defines for values that cannot ride in a plain ASCII header (non-ASCII
/// characters, padding whitespace, or a literal that would look like the
/// sentinel). Returns nil when the sentinel is present but its payload is not
/// valid base64/UTF-8.
func mcpDecodedHeaderValue(_ raw: String) -> String? {
    let prefix = "=?base64?"
    let suffix = "?="
    guard raw.hasPrefix(prefix), raw.hasSuffix(suffix), raw.count > prefix.count + suffix.count
    else { return raw }
    let encoded = String(raw.dropFirst(prefix.count).dropLast(suffix.count))
    guard let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8)
    else { return nil }
    return decoded
}

/// The HTTP status a JSON-RPC response is returned with.
///
/// Legacy keeps its historical mapping (everything 200 except the 403 scope
/// denial), because a legacy client reads the JSON-RPC error, not the status.
/// Modern makes the protocol-defined failures HTTP-visible, which is what lets
/// a dual-era client tell a modern server from a legacy one by inspecting a
/// 400's body.
func mcpResponseStatus(for response: JSONRPCResponse, era: MCPEra) -> HTTPResponseStatus {
    guard let error = response.error else { return .ok }
    if error.code == JSONRPCError.insufficientScopeCode { return .forbidden }
    guard era == .modern else { return .ok }
    switch error.code {
    case JSONRPCError.headerMismatchCode,
        JSONRPCError.missingRequiredClientCapabilityCode,
        JSONRPCError.unsupportedProtocolVersionCode,
        -32_602:
        return .badRequest
    case -32_601:
        // "If the server does not implement the requested RPC method, it MUST
        // respond with 404 Not Found and a JSON-RPC error with code -32601."
        return .notFound
    default:
        return .ok
    }
}
