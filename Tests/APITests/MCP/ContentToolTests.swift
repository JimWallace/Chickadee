// Tests for the ContentTool abstraction: the type-erased invoke round-trip
// (decode -> execute -> encode), the name-keyed registry, and schema/Input
// agreement.  Uses a dummy in-test tool.

import Core
import Testing
import Vapor

@testable import APIServer

@Suite struct ContentToolTests {
    private struct EchoTool: ContentTool {
        struct Input: Decodable, Sendable { let message: String }
        struct Output: Encodable, Sendable { let echoed: String }

        static let name = "echo"
        static let description = "Echoes its message back."
        static let inputSchema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "message": .object(["type": .string("string")])
            ]),
            "required": .array([.string("message")]),
        ])
        static let requiredScopes: Set<ContentScope> = [.read]

        func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
            Output(echoed: input.message)
        }
    }

    @Test func registryLooksUpByNameAndListsSorted() {
        let registry = ToolRegistry([EchoTool().erased()])
        #expect(registry.tool(named: "echo")?.name == "echo")
        #expect(registry.tool(named: "missing") == nil)
        #expect(registry.all.map(\.name) == ["echo"])
    }

    @Test func erasedInvokeDecodesRunsAndEncodes() async throws {
        try await withApp(try await Application.make(.testing)) { app in
            let request = Request(application: app, on: app.eventLoopGroup.any())
            let context = ToolContext(request: request, subject: "tester", grantedScopes: [.read, .write])
            let result = try await EchoTool().erased().invoke(.object(["message": .string("hi")]), context)
            #expect(result == .object(["echoed": .string("hi")]))
        }
    }

    @Test func erasedInvokeRejectsBadArguments() async throws {
        try await withApp(try await Application.make(.testing)) { app in
            let request = Request(application: app, on: app.eventLoopGroup.any())
            let context = ToolContext(request: request, subject: "tester", grantedScopes: [.read])
            await #expect(throws: MCPToolError.self) {
                _ = try await EchoTool().erased().invoke(.object(["nope": .int(1)]), context)
            }
        }
    }

    @Test func schemaRequiredFieldAgreesWithInput() throws {
        // The schema marks `message` required; Input decodes when present and
        // fails when absent — so schema and Swift type agree.
        #expect(throws: Never.self) {
            _ = try JSONValue.object(["message": .string("ok")]).decoded(as: EchoTool.Input.self)
        }
        #expect(throws: (any Error).self) {
            _ = try JSONValue.object([:]).decoded(as: EchoTool.Input.self)
        }
    }
}
