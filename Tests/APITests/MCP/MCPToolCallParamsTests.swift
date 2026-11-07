// Tests/APITests/MCP/MCPToolCallParamsTests.swift
//
// `MCPToolCall(params:)` reads a tools/call's name and arguments straight
// from the JSON tree, where the dispatcher used to round-trip the whole
// params through an encoder and a decoder. These pin that the two agree on
// every shape a client can send, and that the SSE frame written straight
// into a buffer has the bytes of the string frame.

import Core
import Foundation
import NIOCore
import Testing

@testable import APIServer

@Suite struct MCPToolCallParamsTests {
    /// The decode the dispatcher used before: the synthesized `Decodable`,
    /// through a JSON round trip.
    private static func roundTripped(_ params: JSONValue?) -> MCPToolCall? {
        try? (params ?? .object([:])).decoded(as: MCPToolCall.self)
    }

    /// Params as a client sends them: decoded from JSON text, as the
    /// transport decodes the request body.
    private static func params(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    static let shapes: [String] = [
        #"{"name":"get_suite","arguments":{"assignmentPublicID":"a1","limit":5,"ratio":2.5}}"#,
        #"{"name":"get_suite"}"#,
        #"{"name":"get_suite","arguments":null}"#,
        #"{"name":"get_suite","arguments":[1,2,3]}"#,
        #"{"name":"get_suite","arguments":"text"}"#,
        #"{"name":"get_suite","arguments":{"nested":{"a":[true,null,-0.0,1e20,"é\n\"q\""]}}}"#,
        #"{"name":"get_suite","arguments":{},"_meta":{"progressToken":7}}"#,
        #"{"name":"","arguments":{}}"#,
        #"{"name":7,"arguments":{}}"#,
        #"{"name":null}"#,
        #"{"arguments":{}}"#,
        #"{}"#,
        #"[]"#,
        #""get_suite""#,
        #"null"#,
        #"3"#,
    ]

    @Test(arguments: shapes)
    func readingTheTreeMatchesTheRoundTrip(json: String) throws {
        let params = try Self.params(json)
        let direct = MCPToolCall(params: params)
        let decoded = Self.roundTripped(params)
        #expect((direct == nil) == (decoded == nil))
        #expect(direct?.name == decoded?.name)
        #expect(direct?.arguments == decoded?.arguments)
    }

    @Test func absentParamsReadAsAnEmptyObject() {
        #expect(MCPToolCall(params: nil) == nil)
        #expect(Self.roundTripped(nil) == nil)
    }

    private struct Payload: Encodable {
        let id: Int
        let text: String
        let values: [Double]
    }

    @Test func bufferedSSEFrameHasTheStringFramesBytes() throws {
        let payload = Payload(id: 3, text: "é \"quoted\" \\ / \n line", values: [1, 2.5, -0.0])
        let frame = try MCPTransport.sseMessageFrame(encoding: payload)
        let buffer = try MCPTransport.sseMessageFrameBuffer(encoding: payload)
        #expect(Array(buffer.readableBytesView) == Array(frame.utf8))
    }
}
