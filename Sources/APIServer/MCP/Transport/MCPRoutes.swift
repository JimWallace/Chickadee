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

import Core
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

        // Live-progress streaming: a `validate_assignment` tools/call over an SSE
        // connection that carries a progressToken streams `notifications/progress`
        // (queued → running → done) while it waits, then the final result. This is
        // the one tool wired for live progress; every other call falls through to
        // the generic dispatch below (which still streams its single result as SSE
        // when the client accepts it). Generalizing live progress to all tools
        // needs a Sendable ToolContext — it currently wraps the non-Sendable
        // Request — so the watch runs on the request-independent `application.db`
        // and this stays a contained special case rather than threading a progress
        // sink through the dispatcher.
        if let streaming = try await validationProgressStream(req: req, context: context, rpc: rpcRequest) {
            return streaming
        }

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
    /// `event: message` carrying the compact JSON, then the stream ends. The
    /// generic happy path uses this — every tool except the live-progress
    /// `validate_assignment` stream emits exactly one event. The shape is
    /// forward-compatible: progress notifications can precede the response (which
    /// is exactly what the validation stream does).
    private func eventStreamResponse(_ payload: JSONRPCResponse) throws -> Response {
        let frame = try MCPRoutes.sseMessageFrame(encoding: payload)
        let response = Response(status: .ok, headers: MCPRoutes.sseHeaders())
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

    // MARK: - validate_assignment live progress stream

    /// If `rpc` is a `validate_assignment` tools/call over an SSE connection that
    /// carries a `progressToken`, and the caller is scope-authorized and enrolled
    /// in the assignment's course, returns an SSE response that streams progress
    /// then the result. Returns nil to let the generic dispatch handle every
    /// other case (including the authorization/error responses, so this path
    /// never has to reformat them).
    private func validationProgressStream(
        req: Request, context: ToolContext, rpc: JSONRPCRequest
    ) async throws -> Response? {
        guard clientAcceptsEventStream(req),
            let input = Self.validateAssignmentCall(rpc),
            let token = MCPProgressReporter.token(fromParams: rpc.params),
            context.grantedScopes.isSuperset(of: ValidateAssignmentTool.requiredScopes),
            let assignment = try await assignmentByPublicID(input.assignmentPublicID, on: context.db)
        else { return nil }
        // Authorize against the assignment's course; on failure fall back to the
        // generic dispatch, which produces the proper not-authorized result.
        do {
            try await context.authorizeCourseAccess(
                assignment.courseID, tool: ValidateAssignmentTool.name)
        } catch {
            return nil
        }

        // Audit the call here, since the generic dispatcher (which normally does)
        // is bypassed for the streaming path.
        await dispatcher.auditToolCall(name: ValidateAssignmentTool.name, context: context)

        let application = req.application
        let id = rpc.id ?? .null
        let publicID = assignment.publicID
        let timeout = ValidateAssignmentTool.clampTimeout(input.timeoutSeconds)

        let response = Response(status: .ok, headers: Self.sseHeaders())
        response.body = .init(asyncStream: { writer in
            let reporter = MCPProgressReporter(
                token: token,
                sink: { notification in
                    if let frame = try? Self.sseMessageFrame(encoding: notification) {
                        try? await writer.writeBuffer(ByteBuffer(string: frame))
                    }
                })

            let finalResponse: JSONRPCResponse
            do {
                let outcome = try await watchValidation(
                    on: application.db,
                    assignmentPublicID: publicID,
                    pollInterval: .milliseconds(500),
                    deadline: ContinuousClock().now.advanced(by: .seconds(timeout)),
                    emit: { progress, message in await reporter.report(progress, message: message) })
                let output = ValidateAssignmentTool.Output(
                    assignmentPublicID: outcome.assignmentPublicID,
                    validationStatus: outcome.validationStatus,
                    timedOut: outcome.timedOut)
                let structured = (try? JSONValue(encoding: output)) ?? .object([:])
                finalResponse = .success(id: id, result: mcpToolSuccessResult(structured))
            } catch {
                finalResponse = .failure(
                    id: id, error: .internalError("validate_assignment failed while watching validation."))
            }

            if let frame = try? Self.sseMessageFrame(encoding: finalResponse) {
                try? await writer.writeBuffer(ByteBuffer(string: frame))
            }
            try? await writer.write(.end)
        })
        return response
    }

    /// Decodes `rpc` into a `validate_assignment` tool input, or nil if `rpc`
    /// isn't a tools/call for that tool.
    private static func validateAssignmentCall(_ rpc: JSONRPCRequest) -> ValidateAssignmentTool.Input? {
        guard rpc.method == "tools/call", let params = rpc.params else { return nil }
        struct Call: Decodable {
            let name: String
            let arguments: JSONValue?
        }
        guard let call = try? params.decoded(as: Call.self),
            call.name == ValidateAssignmentTool.name,
            let input = try? (call.arguments ?? .object([:])).decoded(
                as: ValidateAssignmentTool.Input.self)
        else { return nil }
        return input
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
