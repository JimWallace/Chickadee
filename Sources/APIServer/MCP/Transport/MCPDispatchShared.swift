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

// MARK: - initialize

/// What one MCP surface advertises from `initialize`: its capability set,
/// identity, and agent-facing instructions, plus the label its log lines
/// carry ("MCP" / "Admin MCP").
struct MCPInitializeSurface {
    let capabilities: MCPServerCapabilities
    let serverInfo: MCPServerInfo
    let instructions: String
    let logLabel: String
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
    let negotiated =
        client?.protocolVersion.flatMap { requested in
            MCPProtocol.supportedVersions.contains(requested) ? requested : nil
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
