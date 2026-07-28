// APIServer/MCP/Transport/MCPDispatchShared.swift
//
// The surface-agnostic halves of MCP dispatch, shared by the content
// dispatcher (`MCPDispatcher`) and the admin diagnostic dispatcher
// (`AdminMCPDispatcher`) (#1121).  The two surfaces keep separate tool
// protocols, registries, contexts, and scope types on purpose — isolation, so
// a change to one can't destabilize the other (docs/admin-mcp.md §3.4) — but
// the wire behaviour must never drift between them: tools/list entry
// encoding, spec pagination, the tools/call result envelopes, and initialize
// version negotiation all live here, parameterized by capabilities and
// instructions.

import Core
import Logging

// MARK: - tools/list entries

/// The listable surface of a type-erased MCP tool — the fields a
/// `tools/list` entry encodes.  `AnyContentTool` and `AnyDiagnosticTool`
/// both conform.
protocol MCPListableTool {
    var name: String { get }
    var title: String { get }
    var description: String { get }
    var inputSchema: JSONValue { get }
    var outputSchema: JSONValue? { get }
    var annotations: MCPToolAnnotations? { get }
}

/// Encodes the `tools/list` entry for each tool, in the given order.
func mcpToolsListEntries(_ tools: [some MCPListableTool]) -> [JSONValue] {
    tools.map { tool in
        var fields: [String: JSONValue] = [
            "name": .string(tool.name),
            "title": .string(tool.title),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema,
        ]
        if let outputSchema = tool.outputSchema {
            fields["outputSchema"] = outputSchema
        }
        if let annotations = tool.annotations, let encoded = try? JSONValue(encoding: annotations) {
            fields["annotations"] = encoded
        }
        return .object(fields)
    }
}

// MARK: - List pagination

private struct MCPListParams: Decodable {
    let cursor: String?
}

/// Applies spec pagination to a full list result: slices `entries` by the
/// caller's cursor and attaches `nextCursor` while more pages remain.  An
/// unparseable cursor is invalidParams, per the spec.
/// https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/pagination
func mcpPaginatedListResponse(
    id: JSONRPCID, key: String, entries: [JSONValue], params: JSONValue?
) -> JSONRPCResponse {
    let cursor: String?
    do {
        cursor = try (params ?? .object([:])).decoded(as: MCPListParams.self).cursor
    } catch {
        return .failure(id: id, error: .invalidParams("\"cursor\" must be a string."))
    }
    guard let result = MCPListPagination.page(entries, cursor: cursor) else {
        return .failure(id: id, error: .invalidParams("Invalid cursor."))
    }
    var fields: [String: JSONValue] = [key: .array(result.page)]
    if let next = result.nextCursor {
        fields["nextCursor"] = .string(next)
    }
    return .success(id: id, result: .object(fields))
}

// MARK: - tools/call result envelopes

/// Wraps a tool's structured output in the MCP `tools/call` result envelope
/// (`content` text block + `structuredContent` + `isError:false`). Shared by
/// both dispatchers' normal paths and the transport's SSE progress-streaming
/// path so all producers emit identical result shapes.
func mcpToolSuccessResult(_ structured: JSONValue) -> JSONValue {
    let text = (try? structured.encodedString()) ?? ""
    return .object([
        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        "structuredContent": structured,
        "isError": .bool(false),
    ])
}

/// Reports a tool-originated failure inside the result with `isError:true`
/// so the model can see and correct it (rather than a JSON-RPC error).
func mcpToolErrorResult(_ error: MCPToolError) -> JSONValue {
    let message: String
    switch error {
    case .unknownTool(let name):
        message = "Unknown tool: \(name)"
    case .invalidArguments(let tool, let detail):
        message = "Invalid arguments for \(tool): \(detail)"
    case .notAuthorized(let tool, let detail):
        message = "Not authorized for \(tool): \(detail)"
    case .executionFailed(let tool, let detail):
        message = "\(tool) failed: \(detail)"
    }
    return .object([
        "content": .array([.object(["type": .string("text"), "text": .string(message)])]),
        "isError": .bool(true),
    ])
}

// MARK: - Modern (2026-07-28) result envelope

/// Stamps the modern per-result fields onto a successful response: the
/// mandatory `resultType` discriminator and the server's self-identification
/// in `_meta`.  Legacy responses pass through untouched — legacy clients treat
/// an absent `resultType` as `"complete"`, and adding server `_meta` to a
/// revision that never defined it would be noise.
///
/// Applied once at the dispatcher's exit rather than inside every handler, so
/// no result-building code has to know which era it is serving.  Error
/// responses are left alone: they carry `error`, not `result`.
/// https://modelcontextprotocol.io/specification/2026-07-28/basic#requests
func mcpModernized(
    _ response: JSONRPCResponse, era: MCPEra, serverInfo: MCPServerInfo
) -> JSONRPCResponse {
    guard era == .modern, response.error == nil,
        case .object(var fields)? = response.result
    else { return response }
    // "Result responses MUST include a `resultType` field." Every result this
    // server produces is terminal — it never asks the client for input — so
    // the discriminator is always `complete`.
    fields["resultType"] = .string("complete")
    var meta: [String: JSONValue] = [:]
    if case .object(let existing)? = fields["_meta"] { meta = existing }
    if meta[MCPMetaKey.serverInfo] == nil {
        var info: [String: JSONValue] = [
            "name": .string(serverInfo.name),
            "version": .string(serverInfo.version),
        ]
        if let title = serverInfo.title { info["title"] = .string(title) }
        meta[MCPMetaKey.serverInfo] = .object(info)
    }
    fields["_meta"] = .object(meta)
    return .success(id: response.id, result: .object(fields))
}

// MARK: - initialize / server/discover

/// What one MCP surface advertises about itself: its capability set, identity,
/// and agent-facing instructions, plus the label its log lines carry
/// ("MCP" / "Admin MCP").  Shared by the legacy `initialize` handshake and the
/// modern `server/discover` method, so the two can never describe the server
/// differently.
struct MCPInitializeSurface {
    let capabilities: MCPServerCapabilities
    let serverInfo: MCPServerInfo
    let instructions: String
    let logLabel: String
}

/// Builds the modern `server/discover` result: the versions this server
/// speaks, its capabilities, and its instructions.  `serverInfo` is added by
/// `mcpModernized` (it belongs in the result's `_meta`, not the body).
///
/// Deliberately carries no `ttlMs` / `cacheScope`: the instructions embed
/// per-course authoring guidance an instructor can change at any time, and a
/// client caching a stale discover result would keep serving the old guide.
/// https://modelcontextprotocol.io/specification/2026-07-28/server/discover
func mcpDiscoverResult(surface: MCPInitializeSurface) -> JSONValue {
    .object([
        "supportedVersions": .array(MCPProtocol.advertisedVersions.map { .string($0) }),
        "capabilities": (try? JSONValue(encoding: surface.capabilities)) ?? .object([:]),
        "instructions": .string(surface.instructions),
    ])
}

/// Builds the `initialize` response: version negotiation per the lifecycle
/// spec (echo the requested revision when this server supports it; otherwise
/// answer with the latest we speak and let the client decide whether to
/// continue), plus a client-identity log line for operational visibility.
func mcpInitializeResponse(
    id: JSONRPCID,
    params: JSONValue?,
    surface: MCPInitializeSurface,
    logger: Logger?
) -> JSONRPCResponse {
    let client = try? (params ?? .object([:])).decoded(as: MCPInitializeParams.self)
    // Negotiate only among the LEGACY revisions: `initialize` is the legacy
    // handshake, so a client reaching it cannot speak the modern per-request
    // protocol even if it names that version. Answering with the modern
    // revision here would hand a legacy client a protocol it cannot use.
    let negotiated =
        client?.protocolVersion.flatMap { requested in
            MCPProtocol.legacyVersions.contains(requested) ? requested : nil
        } ?? MCPProtocol.version
    if let logger {
        let name = client?.clientInfo?.name ?? "unknown"
        let clientVersion = client?.clientInfo?.version ?? "unknown"
        let requested = client?.protocolVersion ?? "none"
        logger.info(
            "\(surface.logLabel) initialize: client=\(name)/\(clientVersion) requestedProtocolVersion=\(requested) negotiated=\(negotiated)"
        )
    }
    let result = MCPInitializeResult(
        protocolVersion: negotiated,
        capabilities: surface.capabilities,
        serverInfo: surface.serverInfo,
        instructions: surface.instructions
    )
    do {
        return .success(id: id, result: try JSONValue(encoding: result))
    } catch {
        return .failure(id: id, error: .internalError("Failed to encode initialize result."))
    }
}
