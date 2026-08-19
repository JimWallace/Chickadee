// Drift guards for how the achievement condition SIGNALS appear in the
// agent-facing surface: the `initialize` instructions, and every tool's
// description and schema.
//
// WHY THESE EXIST. Four hand-typed signal lists sat across the MCP surface
// before `itemsCovered` was added — the same shape that produced
// `MCPLanguageProse` (a list that went stale one language later) and
// `MCPTierProse` (a list that advertised a tier the type never had). Adding a
// sixth signal would have left an agent reading any of the four told it does
// not exist, while the schema enum it also reads accepted it.
//
// So the expectations here are all derived from `AchievementSignal.allCases`,
// scoped to the WHOLE served catalog rather than to the strings this change
// happened to touch. A seventh signal needs no edit to any MCP prose.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct MCPAchievementSignalCoverageTests {

    /// Every piece of text an agent can actually read.
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

    // MARK: - The schema offers exactly the signals the parser accepts

    @Test func everyAdvertisedSignalValueParses() {
        for value in AchievementSignalValues.all {
            #expect(
                AchievementSignal(rawValue: value) != nil,
                """
                The MCP schema advertises signal "\(value)", which is not an `AchievementSignal` \
                case — a caller can pass schema validation and then be rejected one layer down.
                """)
        }
    }

    @Test func everyRealSignalIsAdvertised() {
        for signal in AchievementSignal.allCases {
            #expect(
                AchievementSignalValues.all.contains(signal.rawValue),
                """
                `AchievementSignal.\(signal)` is not in `AchievementSignalValues.all`, so no MCP \
                tool offers it.
                """)
        }
    }

    // MARK: - No hand-typed signal list survives in the catalog

    /// A truncated list — the failure this change would have caused. Every
    /// proper prefix of `allCases` is a list that stopped short; the derived
    /// rendering is deleted first so a correct list is not mistaken for one.
    ///
    /// Prefixes of length 1 are dropped: a lone signal name appears throughout
    /// legitimate prose ("ignored for testPass") and is no evidence of a list.
    @Test func noTruncatedSignalListSurvivesInTheServedCatalog() {
        let scanned = Self.servedText.replacingOccurrences(
            of: MCPAchievementSignalProse.commaList, with: "\u{00AB}signals\u{00BB}")
        let cases = AchievementSignal.allCases.map(\.rawValue)
        for count in 2..<cases.count {
            let stale = cases.prefix(count).joined(separator: ", ")
            #expect(
                !scanned.contains(stale),
                """
                The served MCP catalog contains "\(stale)" — a signal list that stops short of \
                \(cases.count) signals. Interpolate `MCPAchievementSignalProse.commaList` instead \
                of typing the names.
                """)
        }
    }

    /// The complement: the derived rendering actually reaches the catalog, so
    /// deleting every list would not pass the guard above.
    @Test func theDerivedSignalRenderingIsInterpolatedIntoTheCatalog() {
        #expect(
            Self.servedText.contains(MCPAchievementSignalProse.commaList),
            """
            No served text contains MCPAchievementSignalProse.commaList \
            ("\(MCPAchievementSignalProse.commaList)") verbatim, so either it is unused or a \
            hand-typed list replaced it at its call site.
            """)
    }

    /// Every signal is described, not merely listed. The units clause is the
    /// one per-signal string that cannot be derived from a case name, so the
    /// exhaustive switch behind it is what keeps a new signal from shipping
    /// undescribed — assert the result reaches the catalog naming all of them.
    @Test func everySignalIsDescribedInTheUnitsClause() {
        let clause = MCPAchievementSignalProse.unitsClause
        for signal in AchievementSignal.allCases {
            #expect(
                clause.contains(signal.rawValue),
                "The units clause does not describe `\(signal.rawValue)`: \(clause)")
        }
        #expect(Self.servedText.contains(clause), "the units clause never reaches an agent")
    }
}
