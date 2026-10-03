// Guards the agent-facing description of WHERE an assignment's language comes
// from.
//
// Since #1331 every assignment declares its language and nothing infers one:
// `AssignmentLanguage.resolve(manifest:)` returns `manifest.language` and
// nothing else. The MCP instructions and `set_assignment_language` still told
// every agent the language was "resolved from its graded scripts and its
// starter notebook's kernel" for seven weeks after that (#1933). An agent that
// believes it will expect a new starter notebook or a new `.R` script to move
// the language, and it will not.
//
// Scoped to the whole served catalog, like `MCPLanguageCoverageTests`, because
// the stale sentence lived in three places at once.

import Foundation
import Testing

@testable import APIServer

@Suite struct MCPLanguageDeclarationProseTests {

    /// The server instructions, plus each tool's description and both schemas
    /// rendered as JSON: everything an agent can read.
    private static let servedText: String = {
        var parts = [MCPServerInstructions.text]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for tool in MCPToolCatalog.live.all {
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
    }()

    @Test func theServedCatalogNeverSaysTheLanguageIsInferredFromContent() {
        // A claim that something is worked out from an assignment's content:
        // "derived from the starter notebook's kernel", "resolved from its
        // graded scripts", "inferred from a script's extension", and so on.
        let inferenceClaim =
            #/(?i)(derived|inferred|resolved|detected)\s+from\s+(the\s+|its\s+|a\s+)?(starter\s+)?(notebook|kernel|graded\s+script|script)/#
        let claims = Self.servedText.matches(of: inferenceClaim).map { String($0.output.0) }
        #expect(
            claims.isEmpty,
            """
            The MCP catalog says something is worked out from an assignment's content: \
            \(claims). An assignment's language is declared, never inferred (#1331).
            """)
    }

    /// The positive half: the instructions name both doors an agent uses to
    /// declare a language, so an agent learns how to set it, not only that
    /// nothing guesses it.
    @Test func theInstructionsNameTheToolsThatDeclareTheLanguage() {
        let text = MCPServerInstructions.text
        #expect(text.contains("create_assignment requires the declaration"))
        #expect(text.contains("set_assignment_language changes it"))
    }
}
