// Tests/APITests/MCP/MCPRoadmapDocSyncTests.swift
//
// #1125 — docs/mcp-authoring-roadmap.md's tool table is the human index of
// the agent catalog and had silently drifted (39 rows vs 40 registered
// tools; `set_time_limit` was missing). Same file-reading pattern as
// MCPAuthorizationCoverageTests: read the doc, assert every registered
// catalog tool name appears in it, so adding a tool without documenting it
// is a build failure instead of quiet drift.

import Foundation
import Testing

@testable import APIServer

@Suite struct MCPRoadmapDocSyncTests {
    private static var roadmapDoc: URL {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/MCP/<thisFile>
        for _ in 0..<4 { url.deleteLastPathComponent() }  // -> repo root
        return url.appendingPathComponent("docs/mcp-authoring-roadmap.md")
    }

    @Test func everyCatalogToolAppearsInTheRoadmapTable() throws {
        let doc = try String(contentsOf: Self.roadmapDoc, encoding: .utf8)
        let registered = MCPToolCatalog.live.all.map(\.name)
        #expect(registered.count >= 40, "catalog unexpectedly small (\(registered.count))")
        for name in registered {
            #expect(
                doc.contains("`\(name)`"),
                """
                MCP tool `\(name)` is registered in MCPToolCatalog.live but does not \
                appear in docs/mcp-authoring-roadmap.md's tool table — add a row \
                (scope + one-line capability) so the human index can't drift (#1125).
                """)
        }
    }
}
