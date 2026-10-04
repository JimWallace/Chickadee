// Drift guards for how the pattern-family and notebook-check kinds appear in
// the agent-facing MCP catalog (#1936).
//
// The ten notebook-check kinds were typed by hand twice, four lines from the
// derived pattern-kind list, and the kinds that accept `expectedVarRef` were
// typed by hand once. `MCPLanguageCoverageTests` caught the same shape for
// languages: a list written when there were N values, still listing N when
// there are N+1. These tests do the same for both kind enums.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct MCPKindProseCoverageTests {

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

    /// The served text with every DERIVED kind rendering cut out, so what is
    /// left can only be hand-typed.
    private static let scanned: String = {
        var text = servedText
        for rendering in [
            MCPPatternKindProse.slashSeparated, MCPPatternKindProse.glossedList,
            MCPPatternKindProse.expectedVarRefKinds,
            MCPNotebookCheckKindProse.slashSeparated, MCPNotebookCheckKindProse.glossedList,
        ] {
            text = text.replacingOccurrences(of: rendering, with: "«derived»")
        }
        return text
    }()

    /// Two wire tokens written next to each other as list items: `a, b`,
    /// `a / b` or `a | b`, with no quotes between them (a JSON `enum` array
    /// quotes every item, and is derived).
    private static func listsAdjacently(_ first: String, _ second: String, in text: String) -> Bool {
        let pattern =
            "\\b\(NSRegularExpression.escapedPattern(for: first))\\s*(,|/|\\|)\\s*(and\\s+|or\\s+)?"
            + "\(NSRegularExpression.escapedPattern(for: second))\\b"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// No hand-typed list of notebook-check kinds survives. Every such list
    /// opens with the first two kinds in declaration order.
    @Test func noHandTypedNotebookCheckKindListSurvives() {
        let tokens = MCPNotebookCheckKindProse.tokens
        #expect(
            !Self.listsAdjacently(tokens[0], tokens[1], in: Self.scanned),
            "a hand-typed list of notebook-check kinds survives in the served catalog")
    }

    /// No hand-typed list of pattern-family kinds survives.
    @Test func noHandTypedPatternKindListSurvives() {
        let tokens = MCPPatternKindProse.tokens
        #expect(
            !Self.listsAdjacently(tokens[0], tokens[1], in: Self.scanned),
            "a hand-typed list of pattern-family kinds survives in the served catalog")
    }

    /// Every check kind is named in the instructions and in the
    /// `author_notebook_check` description, with no edit to either.
    @Test func everyNotebookCheckKindIsNamedWhereAnAgentChoosesOne() throws {
        let tool = try #require(MCPToolCatalog.live.all.first { $0.name == "author_notebook_check" })
        for kind in NotebookCheckKind.allCases {
            #expect(MCPServerInstructions.text.contains(kind.rawValue), "the instructions omit \(kind.rawValue)")
            #expect(tool.description.contains(kind.rawValue), "author_notebook_check omits \(kind.rawValue)")
        }
    }

    /// The `expectedVarRef` field names exactly the kinds the save accepts it
    /// on, in both pattern-family tools.
    @Test func expectedVarRefNamesExactlyTheKindsTheSaveAccepts() throws {
        let accepted = PatternKind.allCases.filter(kindSupportsPerStudentExpected)
        #expect(!accepted.isEmpty)
        for name in ["create_pattern_family", "update_pattern_family"] {
            let tool = try #require(MCPToolCatalog.live.all.first { $0.name == name })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(tool.inputSchema)
            let schema = try #require(String(data: data, encoding: .utf8))
            let field = try #require(
                schema.range(of: #""expectedVarRef":\{"description":"[^"]*""#, options: .regularExpression),
                "\(name) has no expectedVarRef description")
            let description = schema[field]
            for kind in PatternKind.allCases {
                #expect(
                    description.contains(kind.rawValue) == accepted.contains(kind),
                    "\(name)'s expectedVarRef description and the save disagree on \(kind.rawValue)")
            }
        }
    }
}
