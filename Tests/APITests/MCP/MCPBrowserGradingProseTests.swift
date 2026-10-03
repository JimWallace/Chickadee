// Guards what the two MCP surfaces tell an agent about browser grading.
//
// Pyodide was removed in v0.5.19: every editor kernel and every browser grader
// is a xeus kernel. Four agent-facing strings still said "graded in-browser via
// Pyodide" (#1934), and the instructions gave Python's import-quarantine rule
// as if it held for every notebook, when only `extractPython` quarantines.
//
// Scoped to the whole served text of BOTH catalogs, because the stale name
// lived in the content surface and the admin surface at once.

import Foundation
import Testing

@testable import APIServer

@Suite struct MCPBrowserGradingProseTests {

    /// The instructions plus each tool's title, description and both schemas
    /// rendered as JSON: everything an agent can read on one surface.
    private static func servedText(instructions: String, tools: [some MCPListableTool]) -> String {
        var parts = [instructions]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for tool in tools {
            parts.append(tool.title)
            parts.append(tool.description)
            for schema in [tool.inputSchema, tool.outputSchema] {
                guard let schema,
                    let data = try? encoder.encode(schema),
                    let json = String(data: data, encoding: .utf8)
                else { continue }
                parts.append(json)
            }
        }
        return parts.joined(separator: "\n")
    }

    @Test func theContentCatalogNeverNamesPyodide() {
        let text = Self.servedText(
            instructions: MCPServerInstructions.text, tools: MCPToolCatalog.live.all)
        #expect(
            text.range(of: "pyodide", options: .caseInsensitive) == nil,
            "The content MCP catalog names Pyodide, which was removed in v0.5.19.")
    }

    @Test func theAdminCatalogNeverNamesPyodide() {
        let text = Self.servedText(
            instructions: AdminMCPServerInstructions.text, tools: AdminMCPToolCatalog.live.all)
        #expect(
            text.range(of: "pyodide", options: .caseInsensitive) == nil,
            "The admin MCP catalog names Pyodide, which was removed in v0.5.19.")
    }

    /// Only `extractPython` quarantines a top-level statement into
    /// `if __name__ == "__main__":`. The instructions must scope that rule to
    /// Python before they state it.
    @Test func theImportQuarantineRuleIsScopedToPythonNotebooks() throws {
        let text = MCPServerInstructions.text
        let scope = try #require(text.range(of: "In a PYTHON notebook"))
        let rule = try #require(text.range(of: "if __name__ =="))
        #expect(scope.lowerBound < rule.lowerBound)
    }
}
