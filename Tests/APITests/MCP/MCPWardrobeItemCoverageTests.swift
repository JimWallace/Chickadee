// Drift guards for how the grantable wardrobe items appear in the agent-facing
// surface (docs/achievement-rewards.md, S2): the schema offers exactly
// `WardrobeItem.grantable`, the derived rendering reaches the served catalog,
// and no hand-typed list stops short. A new grantable item needs no edit to
// any MCP prose.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct MCPWardrobeItemCoverageTests {

    private static let servedText = MCPServedText.text

    @Test func theSchemaOffersExactlyTheGrantableItems() {
        #expect(MCPWardrobeItemProse.values == WardrobeItem.grantable.map(\.rawValue))
        for value in MCPWardrobeItemProse.values {
            let item = WardrobeItem(rawValue: value)
            #expect(item.map { WardrobeItem.grantable.contains($0) } == true, "\(value) is not grantable")
        }
    }

    @Test func theRowSchemaOffersTheRewardFields() throws {
        let schema = try #require(String(bytes: try JSONEncoder().encode(achievementRowSchema), encoding: .utf8))
        for value in MCPWardrobeItemProse.values {
            #expect(schema.contains(value), "the row schema does not offer \(value)")
        }
        for type in RewardType.allCases {
            #expect(schema.contains(type.rawValue), "the row schema does not offer \(type)")
        }
    }

    @Test func theDerivedRenderingReachesTheCatalog() {
        #expect(Self.servedText.contains(MCPWardrobeItemProse.commaList))
        for item in WardrobeItem.grantable {
            #expect(Self.servedText.contains("\(item.rawValue) (\(item.displayName))"))
        }
    }

    /// Every proper prefix of the grantable list, typed out, is a list that
    /// stops short. The derived rendering is deleted first.
    @Test func noTruncatedItemListSurvives() {
        let scanned = Self.servedText.replacingOccurrences(of: MCPWardrobeItemProse.commaList, with: "«items»")
        let rendered = WardrobeItem.grantable.map { "\($0.rawValue) (\($0.displayName))" }
        for count in 1..<rendered.count {
            let stale = rendered.prefix(count).joined(separator: ", ") + "."
            #expect(!scanned.contains(stale), "the served catalog lists only \(count) grantable items")
        }
    }

    /// No rule item or found item is offered as a reward.
    @Test func noRuleOrFoundItemIsOffered() {
        for item in WardrobeItem.allCases where !WardrobeItem.grantable.contains(item) {
            #expect(!MCPWardrobeItemProse.values.contains(item.rawValue))
        }
    }
}
