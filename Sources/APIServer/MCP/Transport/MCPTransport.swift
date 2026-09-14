// APIServer/MCP/Transport/MCPTransport.swift
//
// The transport mechanics the content (`/mcp`) and admin (`/admin-mcp`)
// endpoints share: the DNS-rebinding guards, body decoding, era resolution,
// response framing (plain JSON or a one-shot SSE stream) and the
// insufficient-scope challenge.  Each endpoint keeps its own principal,
// context and dispatcher — the layer where the two surfaces differ
// (docs/admin-mcp.md §3.4) — and hands the request through here before and
// after dispatch.  Before this type existed the two route collections
// carried byte-identical copies of everything below.
//
// DNS-rebinding mitigation (transport spec §Security): the `Origin` header is
// validated against an allowlist (403 on mismatch), and — because Vapor does
// not do this by default — the `Host` header is pinned to an allowlist too.
// The `MCP-Protocol-Version` header is validated when present (400 on an
// unsupported revision, per §Protocol Version Header).
// https://modelcontextprotocol.io/specification/2025-11-25/basic/transports

import Core
import Foundation
import NIOCore
import Vapor

struct MCPTransport: Sendable {
    let configuration: MCPRoutes.Configuration

    /// What `admit` decided for one POST body.
    enum Admission {
        /// The request passed every transport-level check; dispatch it under
        /// the resolved era.
        case admitted(JSONRPCRequest, era: MCPEra)
        /// The request was answered at the transport layer without dispatch.
        case rejected(Response)
    }

    // MARK: - Before dispatch

    /// Everything that happens before an endpoint looks at its principal: the
    /// Host/Origin guards (thrown 403s), body decoding (400 carrying a JSON-RPC
    /// parse error with a null id, since the request id is unknowable), era
    /// resolution and the per-era protocol rejections.
    ///
    /// The era is decided per request (#1218): a body carrying modern `_meta`
    /// (or a header naming the modern revision) is served statelessly per
    /// 2026-07-28; anything else keeps legacy semantics unchanged.
    func admit(_ req: Request) throws -> Admission {
        try validateHost(req)
        try validateOrigin(req)

        let rpcRequest: JSONRPCRequest
        do {
            rpcRequest = try decodeRequest(req)
        } catch {
            return .rejected(try jsonResponse(.failure(id: .null, error: .parseError()), status: .badRequest))
        }

        let meta = MCPRequestMeta.extract(fromParams: rpcRequest.params)
        let era = mcpEra(of: meta, request: req)
        if era == .modern {
            if !rpcRequest.isNotification,
                let rejection = mcpModernTransportRejection(
                    request: req, rpc: rpcRequest, meta: meta, era: era)
            {
                let failure = JSONRPCResponse.failure(id: rpcRequest.id ?? .null, error: rejection)
                return .rejected(try jsonResponse(failure, status: mcpResponseStatus(for: failure, era: era)))
            }
        } else if let rejection = try protocolVersionRejection(req) {
            return .rejected(rejection)
        }
        return .admitted(rpcRequest, era: era)
    }

    // MARK: - After dispatch

    /// Frames a dispatcher's answer.  A nil response is an accepted
    /// notification (the spec mandates 202 with no body).  A per-tool scope
    /// denial is surfaced as HTTP 403 insufficient_scope so clients see the
    /// authorization failure at the transport layer; this (and the parse-error
    /// 400 in `admit`) stays plain JSON regardless of Accept, because an SSE
    /// body must be HTTP 200.  Modern protocol-defined failures are
    /// HTTP-visible (400 for a bad version/headers, 404 for an unimplemented
    /// method); legacy keeps its historical 200-with-an-error-body shape.  The
    /// happy path (success or an in-result tool error, both HTTP 200) streams
    /// as SSE when the client asked for it, otherwise returns plain JSON.
    func response(for rpcResponse: JSONRPCResponse?, era: MCPEra, req: Request) throws -> Response {
        guard let rpcResponse else {
            return Response(status: .accepted)
        }
        if let error = rpcResponse.error, error.code == JSONRPCError.insufficientScopeCode {
            return try jsonResponse(
                rpcResponse, status: .forbidden, challenge: insufficientScopeChallenge(error))
        }
        let status = mcpResponseStatus(for: rpcResponse, era: era)
        guard status == .ok else {
            return try jsonResponse(rpcResponse, status: status)
        }
        if clientAcceptsEventStream(req) {
            return try eventStreamResponse(rpcResponse)
        }
        return try jsonResponse(rpcResponse, status: .ok)
    }

    // MARK: - Guards

    private func validateHost(_ req: Request) throws {
        guard !configuration.allowedHosts.isEmpty else { return }
        let host = req.headers.first(name: "Host")?.lowercased() ?? ""
        guard configuration.allowedHosts.contains(host) else {
            throw Abort(.forbidden, reason: "Host header is not in the allowlist.")
        }
    }

    private func validateOrigin(_ req: Request) throws {
        // Empty allowlist disables the check (development default) — matches
        // validateHost, so a present Origin isn't rejected out of the box.
        guard !configuration.allowedOrigins.isEmpty else { return }
        // An absent Origin is allowed (non-browser clients: Inspector, curl).
        guard let origin = req.headers.first(name: "Origin") else { return }
        guard configuration.allowedOrigins.contains(origin) else {
            throw Abort(.forbidden, reason: "Origin is not in the allowlist.")
        }
    }

    /// Transport spec §Protocol Version Header: a request declaring an
    /// `MCP-Protocol-Version` this server does not speak is rejected with
    /// HTTP 400 and an `UnsupportedProtocolVersionError` listing the versions
    /// it does support, so a client can retry with a mutually supported one
    /// instead of failing.  An absent header is accepted: every client omits it
    /// on `initialize` (the version isn't negotiated yet), and pre-2025-06-18
    /// clients never send the header at all.
    private func protocolVersionRejection(_ req: Request) throws -> Response? {
        guard let version = req.headers.first(name: MCPHeader.protocolVersion),
            !MCPProtocol.supportedVersions.contains(version)
        else { return nil }
        return try jsonResponse(
            .failure(id: .null, error: .unsupportedProtocolVersion(requested: version)),
            status: .badRequest)
    }

    // MARK: - Body / response helpers

    private func decodeRequest(_ req: Request) throws -> JSONRPCRequest {
        guard var buffer = req.body.data else {
            throw Abort(.badRequest, reason: "Missing request body.")
        }
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        return try JSONDecoder().decode(JSONRPCRequest.self, from: Data(bytes))
    }

    private func jsonResponse(
        _ payload: JSONRPCResponse, status: HTTPResponseStatus, challenge: String? = nil
    ) throws -> Response {
        let data = try JSONEncoder().encode(payload)
        var headers = HTTPHeaders()
        headers.contentType = .json
        if let challenge {
            headers.replaceOrAdd(name: .wwwAuthenticate, value: challenge)
        }
        return Response(status: status, headers: headers, body: .init(data: data))
    }

    /// True when the client advertises it can accept an SSE stream
    /// (`Accept: …, text/event-stream`). Matches case-insensitively and ignores
    /// any `;q=` weighting — presence is enough to opt into the stream form.
    func clientAcceptsEventStream(_ req: Request) -> Bool {
        req.headers[.accept].contains { value in
            value.lowercased().contains("text/event-stream")
        }
    }

    /// Frames a single JSON-RPC response as a one-shot SSE stream: one
    /// `event: message` carrying the compact JSON, then the stream ends. The
    /// generic happy path uses this — every tool except the live-progress
    /// `validate_assignment` stream emits exactly one event. The shape is
    /// forward-compatible: progress notifications can precede the response
    /// (which is exactly what the validation stream does).
    private func eventStreamResponse(_ payload: JSONRPCResponse) throws -> Response {
        let frame = try Self.sseMessageFrame(encoding: payload)
        let response = Response(status: .ok, headers: Self.sseHeaders())
        response.body = .init(stream: { writer in
            var buffer = ByteBufferAllocator().buffer(capacity: frame.utf8.count)
            buffer.writeString(frame)
            writer.write(.buffer(buffer)).whenComplete { _ in
                writer.write(.end, promise: nil)
            }
        })
        return response
    }

    /// SSE response headers. `X-Accel-Buffering: no` + `Cache-Control: no-cache`
    /// defeat reverse-proxy buffering (nginx/squid) that would otherwise hold
    /// events until the connection closes — fatal for incremental streaming.
    static func sseHeaders() -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "text/event-stream")
        headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        headers.replaceOrAdd(name: .connection, value: "keep-alive")
        headers.replaceOrAdd(name: "X-Accel-Buffering", value: "no")
        return headers
    }

    /// One SSE `message` frame: `event:` line, a single `data:` line (compact
    /// JSON has no newlines), terminated by a blank line.
    static func sseMessageFrame(jsonString: String) -> String {
        "event: message\ndata: \(jsonString)\n\n"
    }

    static func sseMessageFrame(encoding value: some Encodable) throws -> String {
        let json = String(bytes: try JSONEncoder().encode(value), encoding: .utf8) ?? ""
        return sseMessageFrame(jsonString: json)
    }

    /// Builds the `WWW-Authenticate: Bearer …, error="insufficient_scope", scope="…"`
    /// header for a 403, mirroring the bearer middleware's challenge format.
    private func insufficientScopeChallenge(_ error: JSONRPCError) -> String {
        var params: [String]
        if let url = configuration.resourceMetadataURL {
            params = ["Bearer resource_metadata=\"\(url)\"", "error=\"insufficient_scope\""]
        } else {
            params = ["Bearer error=\"insufficient_scope\""]
        }
        if case .string(let scope)? = error.data {
            params.append("scope=\"\(scope)\"")
        }
        return params.joined(separator: ", ")
    }
}
