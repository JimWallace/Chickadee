// Drift guards for how the class-activity kinds appear in the agent-facing
// surface — the `MCPLanguageCoverageTests` shape, one enum over. Every list of
// kinds an agent can read derives from `ActivityKind.allCases` through
// `MCPActivityProse`, so a third kind needs no edit to any prose or schema and
// fails here if one was hand-typed.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct MCPActivityCoverageTests {

    /// Every piece of text an agent can read: instructions plus each tool's
    /// name, description and both schemas rendered as JSON.
    private static let servedText: String = {
        var parts = [MCPServerInstructions.text]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for tool in MCPToolCatalog.live.all {
            parts.append(tool.name)
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

    /// Every schema `enum` that names one kind names them all. This is the
    /// guard that works at two kinds, where a proper-prefix scan (the language
    /// guard's shape) has nothing multi-item to catch.
    @Test func everySchemaEnumNamingAKindNamesEveryKind() {
        let kinds = Set(ActivityKind.allCases.map(\.rawValue))
        var enumsSeen = 0
        for tool in MCPToolCatalog.live.all {
            for schema in [tool.inputSchema, tool.outputSchema].compactMap({ $0 }) {
                for values in Self.enumArrays(in: schema) {
                    let named = Set(values.compactMap { if case .string(let s) = $0 { return s } else { return nil } })
                    guard !named.isDisjoint(with: kinds) else { continue }
                    enumsSeen += 1
                    #expect(
                        kinds.isSubset(of: named),
                        "\(tool.name) has an enum naming some activity kinds but not all: \(named)")
                }
            }
        }
        #expect(enumsSeen >= 2, "expected the set and get tools to each carry a kind enum")
    }

    /// The derived renderings actually reach the catalog: without this,
    /// deleting every list would pass the guard above.
    @Test func everyDerivedRenderingIsInterpolatedSomewhere() {
        for (label, rendering) in [
            ("tokens", MCPActivityProse.tokens),
            ("quotedTokenAlternatives", MCPActivityProse.quotedTokenAlternatives),
            ("summaries", MCPActivityProse.summaries),
        ] {
            #expect(
                Self.servedText.contains(rendering),
                "No served text contains MCPActivityProse.\(label) (\"\(rendering)\") verbatim.")
        }
    }

    /// A read tool's serialized description must never name the write tool
    /// (the read-only-mode contract asserts the whole tools/list never does).
    @Test func readToolsDoNotNameTheWriteTool() {
        for tool in MCPToolCatalog.live.all where tool.requiredScopes == [.read] {
            #expect(
                !tool.description.contains(SetActivityTool.name),
                "\(tool.name) names \(SetActivityTool.name) in its description")
        }
    }

    private static func enumArrays(in value: JSONValue) -> [[JSONValue]] {
        switch value {
        case .object(let fields):
            var found: [[JSONValue]] = []
            if case .array(let values)? = fields["enum"] { found.append(values) }
            for (_, child) in fields { found += enumArrays(in: child) }
            return found
        case .array(let items):
            return items.flatMap(enumArrays(in:))
        default:
            return []
        }
    }
}
