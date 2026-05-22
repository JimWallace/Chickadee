// Round-trip tests for the JSON-RPC 2.0 framing types used by the MCP endpoint.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct MCPCodecTests {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    @Test func decodesRequestWithIntegerID() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#
        let request = try decoder.decode(JSONRPCRequest.self, from: Data(json.utf8))
        #expect(request.jsonrpc == "2.0")
        #expect(request.id == .number(1))
        #expect(request.method == "tools/list")
        #expect(request.isNotification == false)
    }

    @Test func decodesRequestWithStringID() throws {
        let json = #"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#
        let request = try decoder.decode(JSONRPCRequest.self, from: Data(json.utf8))
        #expect(request.id == .string("abc"))
        #expect(request.params == nil)
    }

    @Test func decodesNotificationWhenIDAbsent() throws {
        let json = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let request = try decoder.decode(JSONRPCRequest.self, from: Data(json.utf8))
        #expect(request.isNotification)
        #expect(request.id == nil)
    }

    @Test func distinguishesExplicitNullIDFromNotification() throws {
        let json = #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#
        let request = try decoder.decode(JSONRPCRequest.self, from: Data(json.utf8))
        #expect(request.isNotification == false)
        #expect(request.id == .null)
    }

    @Test func encodesSuccessResponse() throws {
        let response = JSONRPCResponse.success(id: .number(7), result: .object(["ok": .bool(true)]))
        let roundTripped = try decoder.decode(JSONValue.self, from: encoder.encode(response))
        #expect(
            roundTripped == .object([
                "jsonrpc": .string("2.0"),
                "id": .int(7),
                "result": .object(["ok": .bool(true)]),
            ]))
    }

    @Test func encodesErrorResponseWithNullIDFallback() throws {
        let response = JSONRPCResponse.failure(id: nil, error: .methodNotFound("frobnicate"))
        let roundTripped = try decoder.decode(JSONValue.self, from: encoder.encode(response))
        #expect(
            roundTripped == .object([
                "jsonrpc": .string("2.0"),
                "id": .null,
                "error": .object([
                    "code": .int(-32_601),
                    "message": .string("Method not found: frobnicate"),
                ]),
            ]))
    }

    @Test func errorResponseOmitsResultKey() throws {
        let response = JSONRPCResponse.failure(id: .number(1), error: .invalidParams("bad"))
        let roundTripped = try decoder.decode(JSONValue.self, from: encoder.encode(response))
        let fields = try #require(roundTripped.objectFields)
        #expect(fields["result"] == nil)
        #expect(fields["error"] != nil)
    }

    @Test func typedDecodingFromJSONValue() throws {
        struct Args: Decodable, Equatable {
            let courseCode: String
            let limit: Int
        }
        let value = JSONValue.object(["courseCode": .string("CS136"), "limit": .int(10)])
        let args = try value.decoded(as: Args.self)
        #expect(args == Args(courseCode: "CS136", limit: 10))
    }
}

private extension JSONValue {
    /// The underlying object dictionary, or nil if this value is not an object.
    var objectFields: [String: JSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }
}
