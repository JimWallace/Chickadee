// Tests/APITests/MCP/MCPModernProtocolTests.swift
//
// The modern (2026-07-28) protocol revision on the content transport (#1218):
// per-request `_meta` in place of the `initialize` handshake, the mandatory
// `server/discover` method, the `resultType` + server-`_meta` result envelope,
// mirrored-header validation, and version negotiation via
// UnsupportedProtocolVersionError.
//
// The server is DUAL-ERA, so every modern assertion here has a legacy
// counterpart proving the 2025-11-25 path is untouched — that is the property
// that keeps today's connector working while the SDKs catch up.

import Core
import Testing
import VaporTesting

@testable import APIServer

@Suite struct MCPModernProtocolTests {
    /// Stands in for MCPBearerAuthMiddleware, as in MCPEndpointTests.
    private struct StubPrincipalMiddleware: AsyncMiddleware {
        let principal: MCPPrincipal
        func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
            request.mcpPrincipal = principal
            return try await next.respond(to: request)
        }
    }

    private func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        let dispatcher = MCPDispatcher(
            serverInfo: MCPServerInfo(name: "Chickadee MCP", version: "test-9.9.9"),
            tools: ToolRegistry([]))
        let principal = MCPPrincipal(subject: "tester", grantedScopes: Set(ContentScope.allCases))
        try app.grouped(StubPrincipalMiddleware(principal: principal))
            .register(collection: MCPRoutes(dispatcher: dispatcher, configuration: .init()))
        return app
    }

    // MARK: - Request builders

    /// A modern request body: `_meta` carries the protocol version and the
    /// required client capabilities.
    private func modernBody(
        method: String, id: Int = 1, version: String = MCPProtocol.modernVersion,
        extraParams: String = ""
    ) -> String {
        """
        {"jsonrpc":"2.0","id":\(id),"method":"\(method)","params":{\(extraParams)"_meta":{\
        "\(MCPMetaKey.protocolVersion)":"\(version)",\
        "\(MCPMetaKey.clientInfo)":{"name":"ExampleClient","version":"1.0.0"},\
        "\(MCPMetaKey.clientCapabilities)":{}}}}
        """
    }

    private func modernHeaders(
        method: String, version: String = MCPProtocol.modernVersion, name: String? = nil
    ) -> HTTPHeaders {
        var headers: HTTPHeaders = [
            "Content-Type": "application/json",
            MCPHeader.protocolVersion: version,
            MCPHeader.method: method,
        ]
        if let name { headers.add(name: MCPHeader.name, value: name) }
        return headers
    }

    private func objectFields(_ body: String) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
        guard case .object(let fields) = value else {
            Issue.record("response body was not a JSON object: \(body)")
            return [:]
        }
        return fields
    }

    private func resultFields(_ body: String) throws -> [String: JSONValue] {
        guard case .object(let result)? = try objectFields(body)["result"] else {
            Issue.record("response carried no result object: \(body)")
            return [:]
        }
        return result
    }

    private func errorFields(_ body: String) throws -> [String: JSONValue] {
        guard case .object(let error)? = try objectFields(body)["error"] else {
            Issue.record("response carried no error object: \(body)")
            return [:]
        }
        return error
    }

    // MARK: - server/discover

    @Test func discoverAdvertisesVersionsCapabilitiesAndInstructions() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(
                .POST, "/mcp", headers: modernHeaders(method: "server/discover"),
                body: ByteBuffer(string: modernBody(method: "server/discover"))
            ) { res async throws in
                #expect(res.status == .ok)
                let result = try resultFields(res.body.string)

                // Supported versions, newest first, so the client can pick one.
                guard case .array(let versions)? = result["supportedVersions"] else {
                    Issue.record("discover carried no supportedVersions")
                    return
                }
                #expect(versions.first == .string(MCPProtocol.modernVersion))
                #expect(versions.contains(.string("2025-11-25")))

                // Capabilities mirror what initialize advertises.
                guard case .object(let capabilities)? = result["capabilities"] else {
                    Issue.record("discover carried no capabilities")
                    return
                }
                #expect(capabilities["tools"] != nil)
                #expect(capabilities["resources"] != nil)

                // Instructions survive into the modern discovery result — the
                // home of the authoring-voice guide.
                guard case .string(let instructions)? = result["instructions"] else {
                    Issue.record("discover carried no instructions")
                    return
                }
                #expect(instructions.contains("Authoring voice for Chickadee assignments"))
            }
        }
    }

    // MARK: - Modern result envelope

    @Test func modernResultsCarryResultTypeAndServerInfo() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(
                .POST, "/mcp", headers: modernHeaders(method: "ping"),
                body: ByteBuffer(string: modernBody(method: "ping"))
            ) { res async throws in
                #expect(res.status == .ok)
                let result = try resultFields(res.body.string)
                #expect(result["resultType"] == .string("complete"))

                guard case .object(let meta)? = result["_meta"],
                    case .object(let serverInfo)? = meta[MCPMetaKey.serverInfo]
                else {
                    Issue.record("modern result carried no server _meta")
                    return
                }
                #expect(serverInfo["name"] == .string("Chickadee MCP"))
                #expect(serverInfo["version"] == .string("test-9.9.9"))
            }
        }
    }

    @Test func legacyResultsAreUnchanged() async throws {
        // The dual-era guarantee: a 2025-11-25 client sees exactly what it saw
        // before — no resultType, no server _meta.
        try await withApp(try await makeApp()) { app in
            let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
            try await app.testing().test(
                .POST, "/mcp", headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: body)
            ) { res async throws in
                #expect(res.status == .ok)
                let result = try resultFields(res.body.string)
                #expect(result["resultType"] == nil)
                #expect(result["_meta"] == nil)
            }
        }
    }

    @Test func legacyInitializeNeverNegotiatesUpIntoTheModernRevision() async throws {
        // `initialize` is the legacy handshake: a client reaching it cannot
        // speak the per-request protocol, so asking for it must not get it.
        try await withApp(try await makeApp()) { app in
            let body = """
                {"jsonrpc":"2.0","id":1,"method":"initialize","params":\
                {"protocolVersion":"\(MCPProtocol.modernVersion)"}}
                """
            try await app.testing().test(
                .POST, "/mcp", headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: body)
            ) { res async throws in
                #expect(res.status == .ok)
                #expect(try resultFields(res.body.string)["protocolVersion"] == .string("2025-11-25"))
            }
        }
    }

    // MARK: - Version negotiation

    @Test func unsupportedModernVersionListsSupportedVersions() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(
                .POST, "/mcp", headers: modernHeaders(method: "ping", version: "1900-01-01"),
                body: ByteBuffer(string: modernBody(method: "ping", version: "1900-01-01"))
            ) { res async throws in
                #expect(res.status == .badRequest)
                let error = try errorFields(res.body.string)
                #expect(error["code"] == .int(JSONRPCError.unsupportedProtocolVersionCode))
                guard case .object(let data)? = error["data"],
                    case .array(let supported)? = data["supported"]
                else {
                    Issue.record("UnsupportedProtocolVersionError carried no supported list")
                    return
                }
                #expect(supported.contains(.string(MCPProtocol.modernVersion)))
                #expect(data["requested"] == .string("1900-01-01"))
            }
        }
    }

    // MARK: - Mirrored header validation

    @Test func mismatchedMethodHeaderIsRejected() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(
                .POST, "/mcp", headers: modernHeaders(method: "tools/list"),
                body: ByteBuffer(string: modernBody(method: "ping"))
            ) { res async throws in
                #expect(res.status == .badRequest)
                #expect(try errorFields(res.body.string)["code"] == .int(JSONRPCError.headerMismatchCode))
            }
        }
    }

    @Test func missingMethodHeaderIsRejected() async throws {
        try await withApp(try await makeApp()) { app in
            var headers: HTTPHeaders = ["Content-Type": "application/json"]
            headers.add(name: MCPHeader.protocolVersion, value: MCPProtocol.modernVersion)
            try await app.testing().test(
                .POST, "/mcp", headers: headers,
                body: ByteBuffer(string: modernBody(method: "ping"))
            ) { res async throws in
                #expect(res.status == .badRequest)
                #expect(try errorFields(res.body.string)["code"] == .int(JSONRPCError.headerMismatchCode))
            }
        }
    }

    @Test func toolsCallRequiresAMatchingNameHeader() async throws {
        try await withApp(try await makeApp()) { app in
            let body = modernBody(method: "tools/call", extraParams: #""name":"list_courses","arguments":{},"#)
            // Wrong name in the header → rejected before the tool ever runs.
            try await app.testing().test(
                .POST, "/mcp", headers: modernHeaders(method: "tools/call", name: "get_suite"),
                body: ByteBuffer(string: body)
            ) { res async throws in
                #expect(res.status == .badRequest)
                #expect(try errorFields(res.body.string)["code"] == .int(JSONRPCError.headerMismatchCode))
            }
            // Absent name header → equally a mismatch (it is required here).
            try await app.testing().test(
                .POST, "/mcp", headers: modernHeaders(method: "tools/call"),
                body: ByteBuffer(string: body)
            ) { res async throws in
                #expect(res.status == .badRequest)
                #expect(try errorFields(res.body.string)["code"] == .int(JSONRPCError.headerMismatchCode))
            }
        }
    }

    @Test func base64SentinelNameHeaderIsDecodedBeforeComparing() async throws {
        // A value that cannot ride in a plain ASCII header travels in the
        // =?base64?…?= sentinel; the server must decode before comparing.
        #expect(mcpDecodedHeaderValue("=?base64?SGVsbG8sIOS4lueVjA==?=") == "Hello, 世界")

        try await withApp(try await makeApp()) { app in
            // A unicode tool name, which cannot ride raw in an HTTP header.
            // Dispatch gets past validation to the (empty) tool registry and
            // answers "unknown tool" (-32602) — reaching that error is the
            // proof that the header check passed rather than rejecting with
            // -32020. Stays off the DB-backed paths, since this fixture app
            // has no database configured.
            let toolName = "café_tool"
            let body = modernBody(method: "tools/call", extraParams: #""name":"café_tool","arguments":{},"#)
            let encodedName = "=?base64?" + Data(toolName.utf8).base64EncodedString() + "?="

            try await app.testing().test(
                .POST, "/mcp", headers: modernHeaders(method: "tools/call", name: encodedName),
                body: ByteBuffer(string: body)
            ) { res async throws in
                let error = try errorFields(res.body.string)
                #expect(error["code"] != .int(JSONRPCError.headerMismatchCode))
                #expect(error["code"] == .int(-32_602))
            }

            // A plain ASCII value carries no sentinel and passes through
            // untouched, matching the body the same way.
            let plainBody = modernBody(
                method: "tools/call", extraParams: #""name":"plain_tool","arguments":{},"#)
            try await app.testing().test(
                .POST, "/mcp", headers: modernHeaders(method: "tools/call", name: "plain_tool"),
                body: ByteBuffer(string: plainBody)
            ) { res async throws in
                #expect(try errorFields(res.body.string)["code"] != .int(JSONRPCError.headerMismatchCode))
            }
        }
    }

    @Test func modernRequestMissingRequiredMetaIsMalformed() async throws {
        // A modern header with no `_meta` at all: the required per-request
        // fields are missing, so this is invalid params, not a legacy request.
        try await withApp(try await makeApp()) { app in
            let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
            try await app.testing().test(
                .POST, "/mcp", headers: modernHeaders(method: "ping"),
                body: ByteBuffer(string: body)
            ) { res async throws in
                #expect(res.status == .badRequest)
                #expect(try errorFields(res.body.string)["code"] == .int(-32_602))
            }
        }
    }

    @Test func modernRequestMissingClientCapabilitiesIsMalformed() async throws {
        try await withApp(try await makeApp()) { app in
            let body = """
                {"jsonrpc":"2.0","id":1,"method":"ping","params":{"_meta":{\
                "\(MCPMetaKey.protocolVersion)":"\(MCPProtocol.modernVersion)"}}}
                """
            try await app.testing().test(
                .POST, "/mcp", headers: modernHeaders(method: "ping"),
                body: ByteBuffer(string: body)
            ) { res async throws in
                #expect(res.status == .badRequest)
                #expect(try errorFields(res.body.string)["code"] == .int(-32_602))
            }
        }
    }

    // MARK: - Modern status codes

    @Test func unknownModernMethodIs404() async throws {
        // How a modern client distinguishes "this server does not implement
        // that method" from a legacy server with no modern endpoint at all.
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(
                .POST, "/mcp", headers: modernHeaders(method: "frobnicate"),
                body: ByteBuffer(string: modernBody(method: "frobnicate"))
            ) { res async throws in
                #expect(res.status == .notFound)
                #expect(try errorFields(res.body.string)["code"] == .int(-32_601))
            }
        }
    }

    @Test func unknownLegacyMethodStaysA200WithAnErrorBody() async throws {
        try await withApp(try await makeApp()) { app in
            let body = #"{"jsonrpc":"2.0","id":1,"method":"frobnicate"}"#
            try await app.testing().test(
                .POST, "/mcp", headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: body)
            ) { res async throws in
                #expect(res.status == .ok)
                #expect(try errorFields(res.body.string)["code"] == .int(-32_601))
            }
        }
    }

    // MARK: - Era resolution (pure)

    @Test func metaExtractionReadsTheReservedKeys() {
        let params = JSONValue.object([
            "_meta": .object([
                MCPMetaKey.protocolVersion: .string(MCPProtocol.modernVersion),
                MCPMetaKey.clientInfo: .object([
                    "name": .string("ExampleClient"), "version": .string("1.0.0"),
                ]),
                MCPMetaKey.clientCapabilities: .object([:]),
            ])
        ])
        let meta = MCPRequestMeta.extract(fromParams: params)
        #expect(meta.protocolVersion == MCPProtocol.modernVersion)
        #expect(meta.hasClientCapabilities)
        #expect(meta.clientName == "ExampleClient")
        #expect(meta.clientVersion == "1.0.0")
        #expect(meta.declaresModernProtocol)

        let bare = MCPRequestMeta.extract(fromParams: .object(["name": .string("x")]))
        #expect(!bare.declaresModernProtocol)
        #expect(bare.protocolVersion == nil)
    }

    @Test func malformedBase64SentinelIsRejectedNotPassedThrough() {
        #expect(mcpDecodedHeaderValue("plain-value") == "plain-value")
        #expect(mcpDecodedHeaderValue("=?base64?not valid base64!?=") == nil)
    }
}
