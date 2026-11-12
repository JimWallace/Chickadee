// Tests/CoreTests/WardrobeGrantableTests.swift
//
// The grantable pool (docs/achievement-rewards.md, decision 4, slice S2): the
// items an achievement may grant have no built-in rule, so no rule ever earns
// one, and a wardrobe reward decodes from a manifest saved before it existed.

import Core
import Foundation
import Testing

@Suite struct WardrobeGrantableTests {

    @Test func theGrantableItemsAreSpectrumAndCrossFade() {
        #expect(WardrobeItem.grantable == [.spectrumRing, .crossFadeRing])
        #expect(WardrobeItem.spectrumRing.value == AvatarBorder.spectrum.rawValue)
        #expect(WardrobeItem.crossFadeRing.value == AvatarBorder.crossfade.rawValue)
        #expect(WardrobeItem.crossFadeRing.displayName == "Cross-fade")
    }

    /// No item is in both sets: a grantable item has no rule, and a rule
    /// item or a found one is never grantable.
    @Test(arguments: WardrobeItem.allCases)
    func everyItemIsRuleFoundOrGrantableAndOnlyOne(item: WardrobeItem) {
        let kinds = [item.hasBuiltInRule, item.isFound, WardrobeItem.grantable.contains(item)]
        #expect(kinds.filter { $0 }.count == 1, "\(item) is \(kinds)")
    }

    /// However much work a student does, no rule earns a grantable item.
    @Test func noWorkEarnsAGrantableItem() {
        let concepts = AssignmentConcept.allCases
        let graded = (0..<12).map { index in
            WardrobeProgress.Graded(
                assignmentID: "a\(index)", attemptNumber: 1, passCount: 4, totalTests: 4,
                secondsBeforeDue: 7 * 86_400, concept: concepts[index % concepts.count])
        }
        let earned = WardrobeItem.earned(by: WardrobeProgress(graded: graded))
        #expect(earned.isDisjoint(with: WardrobeItem.grantable))
        #expect(earned.allSatisfy { $0.hasBuiltInRule })
    }

    @Test func aGrantedRingOpensOnlyOnceHeld() {
        let value = AvatarBorder.crossfade.rawValue
        #expect(AvatarBorder.crossfade.availability == .special)
        #expect(!AvatarCustomization.isOpen(value, for: .border))
        #expect(AvatarCustomization.isOpen(value, for: .border, unlocked: [.crossFadeRing]))
    }

    // MARK: - The reward

    @Test func aRewardWithoutAnItemDecodesAsBefore() throws {
        let json = #"{"type":"badge","label":"Ace","icon":"*"}"#
        let reward = try JSONDecoder().decode(AchievementReward.self, from: Data(json.utf8))
        #expect(reward == AchievementReward(type: .badge, label: "Ace", icon: "*"))
        #expect(reward.item == nil)
        #expect(reward.wardrobeItem == nil)
        let encoded = try #require(String(bytes: try JSONEncoder().encode(reward), encoding: .utf8))
        #expect(!encoded.contains("item"))
    }

    @Test func aWardrobeRewardRoundTrips() throws {
        let reward = AchievementReward(type: .wardrobe, label: "Painted", item: "border.crossfade")
        let back = try JSONDecoder().decode(AchievementReward.self, from: JSONEncoder().encode(reward))
        #expect(back == reward)
        #expect(back.wardrobeItem == .crossFadeRing)
    }

    /// Only a grantable item is granted: a reward naming a rule item, or a
    /// badge carrying an item, grants nothing.
    @Test func onlyAGrantableItemIsGranted() {
        #expect(AchievementReward(type: .wardrobe, label: "x", item: "border.twotone").wardrobeItem == nil)
        #expect(AchievementReward(type: .wardrobe, label: "x", item: "border.nothing").wardrobeItem == nil)
        #expect(AchievementReward(type: .badge, label: "x", item: "border.crossfade").wardrobeItem == nil)
    }
}
