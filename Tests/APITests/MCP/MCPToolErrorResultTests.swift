// Tests/APITests/MCP/MCPToolErrorResultTests.swift
//
// A tool error names the tool the dispatcher called. The name used to ride in
// every MCPToolError, passed by hand 336 times; it now comes from the call
// (#1939), so no tool can name the wrong tool or forget to name one.

import Core
import Testing

@testable import APIServer

@Suite struct MCPToolErrorResultTests {

    @Test func theResultNamesTheToolTheDispatcherCalled() {
        let cases: [(MCPToolError, String)] = [
            (.invalidArguments(detail: "bad"), "Invalid arguments for update_assignment: bad"),
            (.notAuthorized(detail: "no"), "Not authorized for update_assignment: no"),
            (.executionFailed(detail: "boom"), "update_assignment failed: boom"),
            (.unknownTool("nope"), "Unknown tool: nope"),
        ]
        for (error, message) in cases {
            let result = mcpToolErrorResult(error, tool: "update_assignment")
            let expected = JSONValue.object([
                "content": .array([.object(["type": .string("text"), "text": .string(message)])]),
                "isError": .bool(true),
            ])
            #expect(result == expected, "\(error)")
        }
    }
}
