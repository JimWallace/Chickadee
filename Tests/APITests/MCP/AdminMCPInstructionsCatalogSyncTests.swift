// Drift guards for the agent-facing copy of the ADMIN DIAGNOSTIC MCP surface.
// The server-level instructions (`AdminMCPServerInstructions.text`, returned
// from `initialize`) and each tool's description/schema/annotations are
// hand-maintained and must stay in sync with the live catalog
// (`AdminMCPToolCatalog.live`).  These turn that convention into a build
// failure: adding a diagnostic tool without teaching the instructions about it,
// shipping an empty description, or contradicting the read-only posture fails
// here instead of silently degrading what a connected agent sees.  Mirrors
// `MCPInstructionsCatalogSyncTests` for the content surface.

import Core
import Testing

@testable import APIServer

@Suite struct AdminMCPInstructionsCatalogSyncTests {
    private let tools = AdminMCPToolCatalog.live.all
    private let instructions = AdminMCPServerInstructions.text

    @Test func catalogHasUniqueSnakeCaseNames() {
        // A wholesale catalog regression (e.g. an empty registry from a bad
        // merge) should fail loudly, not pass the per-tool loops vacuously.
        #expect(tools.count >= 16)
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
                "AdminMCPServerInstructions.text never mentions \(tool.name) — update the instructions when changing the catalog"
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

    @Test func everyDescriptionStatesReadOnly() {
        // The whole surface is read-only and the no-student-data guarantee is
        // load-bearing — every tool's own description must say so, so an agent
        // reading a single tool (not just the server instructions) still knows.
        for tool in tools {
            #expect(
                tool.description.contains("Read-only"),
                "\(tool.name) description does not state it is Read-only")
        }
    }

    @Test func everyToolIsReadOnlyAndScopedToDiagnosticsRead() throws {
        for tool in tools {
            #expect(
                tool.requiredScopes == [.read],
                "\(tool.name) must require exactly diagnostics:read on the read-only admin surface")
            let annotations = try #require(tool.annotations, "\(tool.name) advertises no annotations")
            #expect(
                annotations.readOnlyHint == true,
                "\(tool.name) must advertise readOnlyHint:true")
        }
    }
}
