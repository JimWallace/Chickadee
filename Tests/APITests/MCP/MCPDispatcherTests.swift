// Unit tests for the MCP JSON-RPC dispatcher: lifecycle methods, notification
// handling, and error mapping.  Pure logic — no Vapor app required.

import Core
import Testing

@testable import APIServer

@Suite struct MCPDispatcherTests {
    private let dispatcher = MCPDispatcher(
        serverInfo: MCPServerInfo(name: "Chickadee MCP", version: "test-1.2.3")
    )

    private func request(
        _ method: String,
        id: JSONRPCID? = .number(1),
        params: JSONValue? = nil
    ) -> JSONRPCRequest {
        JSONRPCRequest(jsonrpc: "2.0", id: id, method: method, params: params)
    }

    @Test func initializeReturnsProtocolVersionAndServerInfo() async throws {
        let response = try #require(await dispatcher.dispatch(request("initialize")))
        let result = try #require(response.result?.objectFields)
        #expect(result["protocolVersion"] == .string("2025-11-25"))

        let serverInfo = try #require(result["serverInfo"]?.objectFields)
        #expect(serverInfo["name"] == .string("Chickadee MCP"))
        #expect(serverInfo["version"] == .string("test-1.2.3"))

        let capabilities = try #require(result["capabilities"]?.objectFields)
        #expect(capabilities["tools"] == .object(["listChanged": .bool(false)]))
        #expect(capabilities["resources"] == .object(["listChanged": .bool(false)]))
    }

    @Test func pingReturnsEmptyObject() async throws {
        let response = try #require(await dispatcher.dispatch(request("ping")))
        #expect(response.result == .object([:]))
        #expect(response.error == nil)
    }

    @Test func notificationReturnsNoResponse() async throws {
        let response = await dispatcher.dispatch(request("notifications/initialized", id: nil))
        #expect(response == nil)
    }

    @Test func unknownMethodReturnsMethodNotFound() async throws {
        let response = try #require(await dispatcher.dispatch(request("frobnicate")))
        #expect(response.error?.code == -32_601)
    }

    @Test func unknownNotificationIsSilentlyIgnored() async throws {
        let response = await dispatcher.dispatch(request("frobnicate", id: nil))
        #expect(response == nil)
    }

    @Test func badJSONRPCVersionReturnsInvalidRequest() async throws {
        let bad = JSONRPCRequest(jsonrpc: "1.0", id: .number(9), method: "ping", params: nil)
        let response = try #require(await dispatcher.dispatch(bad))
        #expect(response.error?.code == -32_600)
    }

    @Test func toolsListIsEmptyForNow() async throws {
        let response = try #require(await dispatcher.dispatch(request("tools/list")))
        #expect(response.result == .object(["tools": .array([])]))
    }

    @Test func resourcesListIsEmptyForNow() async throws {
        let response = try #require(await dispatcher.dispatch(request("resources/list")))
        #expect(response.result == .object(["resources": .array([])]))
    }
}

private extension JSONValue {
    /// The underlying object dictionary, or nil if this value is not an object.
    var objectFields: [String: JSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }
}
