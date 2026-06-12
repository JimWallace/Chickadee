// Drift guards for the agent-facing copy of the MCP server.  The server-level
// instructions (`MCPServerInstructions.text`, returned from `initialize`) and
// each tool's description/schema/annotations are maintained by hand and must
// stay in sync with the live catalog (`MCPToolCatalog.live`).  These tests
// turn that convention into a build failure: adding a tool without teaching
// the instructions about it — or dropping its output schema or annotations —
// fails here instead of silently degrading what connected agents see.

import Core
import Testing

@testable import APIServer

@Suite struct MCPInstructionsCatalogSyncTests {
    private let tools = MCPToolCatalog.live.all
    private let instructions = MCPServerInstructions.text

    @Test func catalogHasUniqueSnakeCaseNames() {
        // A wholesale catalog regression (e.g. an empty registry from a bad
        // merge) should fail loudly, not pass the per-tool loops vacuously.
        #expect(tools.count >= 30)
        #expect(Set(tools.map(\.name)).count == tools.count)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz_")
        for tool in tools {
            #expect(
                !tool.name.isEmpty && tool.name.allSatisfy { allowed.contains($0) },
                "\(tool.name) is not lower_snake_case")
        }
    }

    @Test func everyCatalogToolIsMentionedInInstructions() {
        for tool in tools {
            #expect(
                instructions.contains(tool.name),
                "MCPServerInstructions.text never mentions \(tool.name) — update the instructions when changing the catalog"
            )
        }
    }

    @Test func everyToolHasDescriptionAndObjectInputSchema() {
        for tool in tools {
            #expect(!tool.description.isEmpty, "\(tool.name) has an empty description")
            guard case .object(let schema) = tool.inputSchema else {
                Issue.record("\(tool.name) inputSchema is not a JSON object")
                continue
            }
            #expect(
                schema["type"] == .string("object"),
                "\(tool.name) inputSchema must declare type:object")
        }
    }

    @Test func everyToolDeclaresAnOutputSchema() {
        // All tools ship an outputSchema today; keep it that way so clients
        // can always validate the structuredContent a tool returns.
        for tool in tools {
            #expect(
                tool.outputSchema != nil,
                "\(tool.name) declares no outputSchema — the structuredContent shape is part of the advertised contract"
            )
        }
    }

    @Test func annotationsAgreeWithRequiredScopes() throws {
        for tool in tools {
            #expect(!tool.requiredScopes.isEmpty, "\(tool.name) requires no scopes")
            let annotations = try #require(
                tool.annotations, "\(tool.name) advertises no annotations")
            let isReadOnly = tool.requiredScopes == [.read]
            #expect(
                annotations.readOnlyHint == isReadOnly,
                "\(tool.name) readOnlyHint must agree with its required scopes")
        }
    }
}
