// APIServer/MCP/Transport/MCPRoutes.swift
//
// The MCP Streamable HTTP transport, mounted at a single endpoint (`/mcp`).
//
// A POST carries one JSON-RPC request. The response is returned either as plain
// JSON (the default) or — when the client advertises `Accept: text/event-stream`
// — as a single-shot SSE stream framing the same JSON-RPC response as an
// `event: message`. Content negotiation is the only difference; the dispatched
// result is identical. The SSE form is what the Claude connector speaks and is
// forward-compatible: `notifications/progress` events can later be interleaved
// before the final response without changing the tool contract. The transport
// stays stateless (no `Mcp-Session-Id` / `Last-Event-ID` resumability), and the
// standalone server-initiated stream is still unsupported, so GET/DELETE 405.
//
// DNS-rebinding mitigation (transport spec §Security): the `Origin` header is
// validated against an allowlist (403 on mismatch), and — because Vapor does
// not do this by default — the `Host` header is pinned to an allowlist too.
// https://modelcontextprotocol.io/specification/2025-11-25/basic/transports

import Foundation
import NIOCore
import Vapor

struct MCPRoutes: RouteCollection {
    let dispatcher: MCPDispatcher
    let configuration: Configuration

    /// Transport-level guards.  Both allowlists default to empty, which means
    /// "allow any" — production configuration supplies explicit values.
    struct Configuration: Sendable {
        /// Permitted `Host` header values (`host[:port]`, compared lowercased).
        /// Empty disables the check.
        var allowedHosts: Set<String>
        /// Permitted `Origin` header values.  A request whose `Origin` is
        /// present and not listed is rejected (403).  An absent `Origin` is
        /// allowed, so non-browser clients (MCP Inspector, curl) still work.
        var allowedOrigins: Set<String>
        /// RFC 9728 metadata URL echoed in the `WWW-Authenticate` challenge when
        /// a tool call is rejected for insufficient scope.  Nil omits it.
        var resourceMetadataURL: String?

        init(
            allowedHosts: Set<String> = [],
            allowedOrigins: Set<String> = [],
            resourceMetadataURL: String? = nil
        ) {
            self.allowedHosts = allowedHosts
            self.allowedOrigins = allowedOrigins
            self.resourceMetadataURL = resourceMetadataURL
        }
    }

    func boot(routes: RoutesBuilder) throws {
        let group = routes.grouped("mcp")
        group.post(use: handlePost)
        group.on(.GET, use: streamingUnsupported)
        group.on(.DELETE, use: streamingUnsupported)
    }

    // MARK: - Handlers

    func handlePost(req: Request) async throws -> Response {
        try validateHost(req)
        try validateOrigin(req)

        let rpcRequest: JSONRPCRequest
        do {
            rpcRequest = try decodeRequest(req)
        } catch {
            // Unparseable body: HTTP 400 carrying a JSON-RPC parse error with a
            // null id (the request id is unknowable).
            return try jsonResponse(.failure(id: .null, error: .parseError()), status: .badRequest)
        }

        // The route is mounted behind MCPBearerAuthMiddleware, which
        // authenticates the caller and populates `request.mcpPrincipal` (or
        // rejects with 401/403) before dispatch ever runs.
        guard let principal = req.mcpPrincipal else {
            throw Abort(.unauthorized, reason: "MCP request reached the transport without an authenticated principal.")
        }
        let context = ToolContext(
            request: req,
            subject: principal.subject,
            grantedScopes: principal.grantedScopes,
            actingClientID: principal.actingClientID,
            actingClientName: principal.actingClientName
        )
        guard let rpcResponse = await dispatcher.dispatch(rpcRequest, context: context) else {
            // A notification was accepted; the spec mandates 202 with no body.
            return Response(status: .accepted)
        }
        // A per-tool scope denial is surfaced as HTTP 403 insufficient_scope so
        // clients see the authorization failure at the transport layer. This
        // (and the parse-error 400 above) stays plain JSON regardless of Accept:
        // an SSE body must be HTTP 200, so a non-200 status couldn't carry it.
        if let error = rpcResponse.error, error.code == JSONRPCError.insufficientScopeCode {
            return try jsonResponse(
                rpcResponse, status: .forbidden, challenge: insufficientScopeChallenge(error))
        }
        // Happy path (success or an in-result tool error, both HTTP 200): stream
        // it as SSE when the client asked for it, otherwise return plain JSON.
        if clientAcceptsEventStream(req) {
            return try eventStreamResponse(rpcResponse)
        }
        return try jsonResponse(rpcResponse, status: .ok)
    }

    func streamingUnsupported(req: Request) async throws -> Response {
        // POST may return an SSE stream (see eventStreamResponse), but the
        // standalone server-initiated stream (GET) and session teardown (DELETE)
        // are unused by the stateless model — there's no session to resume or
        // delete — so both stay 405.
        // https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
        throw Abort(.methodNotAllowed)
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
    private func clientAcceptsEventStream(_ req: Request) -> Bool {
        req.headers[.accept].contains { value in
            value.lowercased().contains("text/event-stream")
        }
    }

    /// Frames a single JSON-RPC response as a one-shot SSE stream: one
    /// `event: message` carrying the compact JSON, then the stream ends. This is
    /// the Streamable HTTP "POST returns an SSE stream" form; we emit exactly one
    /// event (no progress notifications yet), but the shape is forward-compatible
    /// — additional `notifications/progress` events could precede the response.
    ///
    /// `X-Accel-Buffering: no` + `Cache-Control: no-cache` defeat reverse-proxy
    /// buffering (nginx/squid) that would otherwise hold the event until the
    /// connection closes, which is fatal for incremental streaming.
    private func eventStreamResponse(_ payload: JSONRPCResponse) throws -> Response {
        let json = String(bytes: try JSONEncoder().encode(payload), encoding: .utf8) ?? ""
        // SSE framing: `event:` line, one `data:` line (compact JSON has no
        // newlines, so a single data line is valid), terminated by a blank line.
        let frame = "event: message\ndata: \(json)\n\n"

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "text/event-stream")
        headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        headers.replaceOrAdd(name: .connection, value: "keep-alive")
        headers.replaceOrAdd(name: "X-Accel-Buffering", value: "no")

        let response = Response(status: .ok, headers: headers)
        response.body = .init(stream: { writer in
            var buffer = ByteBufferAllocator().buffer(capacity: frame.utf8.count)
            buffer.writeString(frame)
            writer.write(.buffer(buffer)).whenComplete { _ in
                writer.write(.end, promise: nil)
            }
        })
        return response
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
