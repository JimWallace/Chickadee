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
// The transport mechanics — DNS-rebinding guards, body decoding, era
// resolution, JSON/SSE response framing — are `MCPTransport`, shared with the
// admin endpoint; this collection owns the content principal, the
// `ToolContext`, and the one live-progress streaming special case.
// https://modelcontextprotocol.io/specification/2025-11-25/basic/transports

import Core
import Foundation
import Vapor

struct MCPRoutes: RouteCollection {
    let dispatcher: MCPDispatcher
    let configuration: Configuration

    private var transport: MCPTransport { MCPTransport(configuration: configuration) }

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
        let rpcRequest: JSONRPCRequest
        let era: MCPEra
        switch try transport.admit(req) {
        case .rejected(let response):
            return response
        case .admitted(let admitted, let admittedEra):
            (rpcRequest, era) = (admitted, admittedEra)
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
        if let streaming = try await validationProgressStream(
            req: req, context: context, rpc: rpcRequest, era: era)
        {
            return streaming
        }

        let rpcResponse = await dispatcher.dispatch(rpcRequest, context: context, era: era)
        return try transport.response(for: rpcResponse, era: era, req: req)
    }

    func streamingUnsupported(req: Request) async throws -> Response {
        // POST may return an SSE stream (see eventStreamResponse), but the
        // standalone server-initiated stream (GET) and session teardown (DELETE)
        // are unused by the stateless model — there's no session to resume or
        // delete — so both stay 405.
        // https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
        throw Abort(.methodNotAllowed)
    }

    // MARK: - validate_assignment live progress stream

    /// If `rpc` is a `validate_assignment` tools/call over an SSE connection that
    /// carries a `progressToken`, and the caller is scope-authorized and enrolled
    /// in the assignment's course, returns an SSE response that streams progress
    /// then the result. Returns nil to let the generic dispatch handle every
    /// other case (including the authorization/error responses, so this path
    /// never has to reformat them).
    private func validationProgressStream(
        req: Request, context: ToolContext, rpc: JSONRPCRequest, era: MCPEra
    ) async throws -> Response? {
        guard transport.clientAcceptsEventStream(req),
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
        // is bypassed for the streaming path. The outcome is delivered over SSE
        // after the watch, so only the target resource is recorded here.
        await dispatcher.auditToolCall(
            name: ValidateAssignmentTool.name, context: context,
            target: MCPAuditTarget(type: .assignment, id: assignment.publicID))

        let application = req.application
        let id = rpc.id ?? .null
        let publicID = assignment.publicID
        let timeout = ValidateAssignmentTool.clampTimeout(input.timeoutSeconds)
        // The streaming path builds its own final response, so it applies the
        // modern envelope itself rather than going through dispatch().
        let serverInfo = dispatcher.serverInfo

        let response = Response(status: .ok, headers: MCPTransport.sseHeaders())
        response.body = .init(asyncStream: { writer in
            let reporter = MCPProgressReporter(
                token: token,
                sink: { notification in
                    if let frame = try? MCPTransport.sseMessageFrame(encoding: notification) {
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
                finalResponse = mcpModernized(
                    .success(id: id, result: mcpToolSuccessResult(structured)),
                    era: era, serverInfo: serverInfo)
            } catch {
                finalResponse = .failure(
                    id: id, error: .internalError("validate_assignment failed while watching validation."))
            }

            if let frame = try? MCPTransport.sseMessageFrame(encoding: finalResponse) {
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

}
