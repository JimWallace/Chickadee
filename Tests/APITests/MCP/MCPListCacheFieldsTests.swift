// Tests/APITests/MCP/MCPListCacheFieldsTests.swift
//
// The 2026-07-28 schema makes `ttlMs` and `cacheScope` REQUIRED on every
// `CacheableResult`: server/discover, tools/list, resources/list and
// resources/read. Claude Code validates them: without both, it rejected
// `tools/list` ("Invalid result for tools/list") after a successful sign-in,
// so the server connected but served no tools. These tests pin the two fields
// on those modern results, on both surfaces, and pin their absence everywhere
// else: on another result and on every legacy result.

import ChickadeeTestSupport
import Core
import Testing

@testable import APIServer

@Suite struct MCPListCacheFieldsTests {
    private let serverInfo = MCPServerInfo(name: "Chickadee MCP", version: "test-9.9.9")

    private func request(_ method: String) -> JSONRPCRequest {
        JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: method, params: nil)
    }

    private func resultFields(_ response: JSONRPCResponse?) throws -> [String: JSONValue] {
        let response = try #require(response)
        #expect(response.error == nil)
        guard case .object(let fields)? = response.result else {
            throw IssueRecorded("response carried no result object")
        }
        return fields
    }

    @Test func modernContentToolsListCarriesTheCacheFields() async throws {
        let dispatcher = MCPDispatcher(serverInfo: serverInfo)
        let fields = try resultFields(await dispatcher.dispatch(request("tools/list"), era: .modern))
        #expect(fields["ttlMs"] == .int(0))
        #expect(fields["cacheScope"] == .string("private"))
        #expect(fields["resultType"] == .string("complete"))
    }

    @Test func modernAdminToolsListCarriesTheCacheFields() async throws {
        let dispatcher = AdminMCPDispatcher(serverInfo: serverInfo)
        let fields = try resultFields(await dispatcher.dispatch(request("tools/list"), era: .modern))
        #expect(fields["ttlMs"] == .int(0))
        #expect(fields["cacheScope"] == .string("private"))
    }

    @Test func modernDiscoverCarriesTheCacheFields() async throws {
        // DiscoverResult is a CacheableResult too. 0 keeps a client from
        // holding an instructor's authoring guidance after they change it.
        for fields in [
            try resultFields(
                await MCPDispatcher(serverInfo: serverInfo).dispatch(
                    request("server/discover"), era: .modern)),
            try resultFields(
                await AdminMCPDispatcher(serverInfo: serverInfo).dispatch(
                    request("server/discover"), era: .modern)),
        ] {
            #expect(fields["ttlMs"] == .int(0))
            #expect(fields["cacheScope"] == .string("private"))
        }
    }

    @Test func modernNonListResultCarriesNoCacheFields() async throws {
        let dispatcher = MCPDispatcher(serverInfo: serverInfo)
        let fields = try resultFields(await dispatcher.dispatch(request("ping"), era: .modern))
        #expect(fields["ttlMs"] == nil)
        #expect(fields["cacheScope"] == nil)
    }

    @Test func legacyToolsListIsUnchanged() async throws {
        let dispatcher = MCPDispatcher(serverInfo: serverInfo)
        let fields = try resultFields(await dispatcher.dispatch(request("tools/list"), era: .legacy))
        #expect(fields["ttlMs"] == nil)
        #expect(fields["cacheScope"] == nil)
        #expect(fields["resultType"] == nil)
    }

    @Test(arguments: [MCPMethod.resourcesList, .resourcesRead])
    func modernizingAResourceResultAddsTheCacheFields(_ method: MCPMethod) throws {
        // The resource methods need a database-backed context to run, so this
        // pins the envelope step they share with tools/list directly.
        let result = JSONRPCResponse.success(id: .number(1), result: .object(["resources": .array([])]))
        let fields = try resultFields(
            mcpModernized(result, era: .modern, serverInfo: serverInfo, method: method))
        #expect(fields["ttlMs"] == .int(0))
        #expect(fields["cacheScope"] == .string("private"))
    }
}
