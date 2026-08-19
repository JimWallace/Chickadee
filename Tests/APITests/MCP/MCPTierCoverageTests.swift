// Drift guards for how the test tiers appear in the AGENT-FACING surface: the
// `initialize` instructions, every tool's description and schema, and the
// "must be one of" errors a rejected call reads back.
//
// WHY THESE EXIST. `TestTier` has three cases. The MCP surface advertised four:
// nine hand-typed strings, plus the schema enum itself, offered a `student`
// tier the type has never had. So an agent could pass `student` through JSON
// Schema validation and be rejected one layer down by `TestTier(rawValue:)` —
// with an error message that listed the same impossible value back at it. The
// web suite editor meanwhile coerced an unrecognized tier to `.pub`, so one
// door silently changed the value and the other refused it.
//
// The language guards next door encode the lesson that a hand-typed list in
// prose goes stale; these encode its mirror image. A truncated list drops a
// real value, and a phantom list adds one that never existed — both are the
// same defect (prose that a compiler cannot check), and both are caught here by
// scoping to the WHOLE served catalog and deriving every expectation from
// `TestTier.allCases`.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct MCPTierCoverageTests {

    /// Every piece of text an agent can actually read: the server instructions,
    /// plus each tool's name, description, and both schemas rendered as JSON.
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

    // MARK: - The schema cannot offer a tier the parser refuses

    /// THE guard this change exists to install, stated as the invariant that was
    /// violated: every value the schema advertises is one the server accepts.
    ///
    /// `author_script` advertised `student` and then threw `invalidArguments` on
    /// it. Anything that can be selected from a schema enum must survive
    /// `TestTier(rawValue:)` — or be the one pseudo-tier that is deliberately
    /// not a tier.
    @Test func everyAdvertisedTierValueIsAcceptedBySomeParser() {
        for value in TestTierValues.withSupport {
            let isRealTier = TestTier(rawValue: value) != nil
            let isSupport = value == TestTierValues.supportPseudoTier
            #expect(
                isRealTier || isSupport,
                """
                The MCP schema advertises tier "\(value)", which is neither a `TestTier` case nor \
                the `support` pseudo-tier — so a caller can pass schema validation and then be \
                rejected by `TestTier(rawValue:)`. Derive the advertised set from \
                `TestTier.allCases` rather than listing it.
                """)
        }
    }

    /// The complement: no real tier is missing from what the schema offers, so a
    /// newly added tier cannot be un-selectable through the MCP surface.
    @Test func everyRealTierIsAdvertised() {
        for tier in TestTier.allCases {
            #expect(
                TestTierValues.tiers.contains(tier.rawValue),
                """
                `TestTier.\(tier)` is not in `TestTierValues.tiers`, so no MCP tool offers it.
                """)
        }
    }

    // MARK: - No hand-typed tier list survives anywhere in the catalog

    /// Catches BOTH failure directions in one scan, by deleting the correct
    /// renderings first and looking at what is left.
    ///
    /// Each rendering is checked against ITS OWN separator, which is what makes
    /// the phantom rule precise rather than merely suspicious. A hand-typed
    /// extra tier continues the list it was typed into, so it appears as the
    /// derived rendering followed by that rendering's separator —
    /// `public/release/secret` + `/`. A derived list followed by a *different*
    /// punctuation mark is ordinary prose ("tier (public/release/secret,
    /// default public)"), and an earlier version of this guard that ignored
    /// which separator followed flagged exactly that sentence.
    ///
    /// Renderings are replaced longest-first, which also matters:
    /// `oneOfListWithSupport` legitimately extends `oneOfList`, so replacing the
    /// shorter one first would leave a remnant that looks like a phantom.
    @Test func noHandTypedTierListSurvivesInTheServedCatalog() {
        // (rendering, the separator that rendering joins with, a unique sentinel)
        let renderings = [
            (MCPTierProse.oneOfListWithSupport, ", ", "\u{00AB}withSupport\u{00BB}"),
            (MCPTierProse.oneOfList, ", ", "\u{00AB}oneOf\u{00BB}"),
            (MCPTierProse.slashAlternatives, "/", "\u{00AB}slash\u{00BB}"),
        ].sorted { $0.0.count > $1.0.count }

        var scanned = Self.servedText
        for (rendering, _, sentinel) in renderings {
            scanned = scanned.replacingOccurrences(of: rendering, with: sentinel)
        }

        // A phantom: a derived list continued by its own separator. This is the
        // exact shape of the `student` defect — "public/release/secret" was
        // right, and a fourth value had been typed onto the end of it.
        for (_, separator, sentinel) in renderings {
            #expect(
                !scanned.contains(sentinel + separator),
                """
                The served MCP catalog continues a correct tier list with "\(separator)" and \
                another value — a tier the schema offers and `TestTier` does not have, which is \
                the `student` defect. Interpolate `MCPTierProse` instead of typing tiers.
                """)
        }

        // A truncation: a proper prefix of a derived list, left behind when a
        // tier is added and the prose is not.
        for stale in Self.staleTierLists() {
            #expect(
                !scanned.contains(stale),
                """
                The served MCP catalog contains "\(stale)" — a tier list that stops short of \
                \(TestTier.allCases.count) tiers. Interpolate the derived rendering from \
                `MCPTierProse` instead of typing the names.
                """)
        }
    }

    /// Every proper prefix of `allCases`, in both list renderings. Single-item
    /// "lists" are dropped: a lone tier name appears throughout legitimate prose
    /// ("a secret test can re-derive a personalized expected answer") and is no
    /// evidence of a list.
    private static func staleTierLists() -> [String] {
        let cases = TestTier.allCases
        guard cases.count > 2 else { return [] }
        var stale: [String] = []
        for count in 2..<cases.count {
            let prefix = cases.prefix(count).map(\.rawValue)
            stale.append(prefix.joined(separator: ", "))
            stale.append(prefix.joined(separator: "/"))
        }
        return stale
    }

    /// The complement: the derived rendering actually REACHES the catalog.
    /// Without this, deleting every tier list would pass the guard above.
    ///
    /// Only `slashAlternatives` is checked here because it is the only rendering
    /// that appears in a tool description or schema. The two list renderings are
    /// used exclusively in thrown `invalidArguments` details, which are not part
    /// of the served catalog — those are asserted directly below, against the
    /// error a rejected call actually produces.
    @Test func theDerivedTierRenderingIsInterpolatedIntoTheCatalog() {
        #expect(
            Self.servedText.contains(MCPTierProse.slashAlternatives),
            """
            No served text contains MCPTierProse.slashAlternatives \
            ("\(MCPTierProse.slashAlternatives)") verbatim, so either it is unused or a \
            hand-typed list replaced it at its call site.
            """)
    }

    // MARK: - The rejection message names only real tiers

    /// `parseOptionalTier`'s error is agent-facing copy too, and it carried the
    /// phantom. It is not reachable from the tool catalog, so the scan above
    /// cannot see it — assert it directly.
    @Test func theTierRejectionMessageListsExactlyTheRealTiers() throws {
        var thrown: String?
        do {
            _ = try parseOptionalTier("student", tool: "author_script")
        } catch let error as MCPToolError {
            thrown = "\(error)"
        }
        let detail = try #require(thrown, "parseOptionalTier accepted a tier TestTier does not have")
        for tier in TestTier.allCases {
            #expect(
                detail.contains(tier.rawValue),
                "The tier rejection message does not name `\(tier.rawValue)`: \(detail)")
        }
        #expect(
            !detail.contains("student"),
            """
            The tier rejection message still offers "student", a tier `TestTier` does not have — \
            so a caller is told to retry with a value that will be rejected again: \(detail)
            """)
    }
}
