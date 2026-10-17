// Tests/APITests/AccountEarnedItemsTests.swift
//
// What the bird card shows of the wardrobe (#2615; docs/student-wardrobe.md,
// E1 to E3): no item a student earns shows until it is earned, and the "Not
// open yet" list holds only the seasonal rings out of their term. How an item
// was earned is the result page's Earned toast to say (EarnedToastTests).

import Core
import Testing

@testable import APIServer

@Suite struct AccountEarnedItemsTests {

    private static let spec = AvatarSpec(
        cap: .ink, wing: .plain, expression: .bright, accessory: .none, accent: .ember, backdrop: .sky,
        tuft: .none, tilt: .upright, border: .none)

    @Test func notOpenYetHoldsOnlySeasonalRings() {
        let picker = AvatarPickerContext(for: Self.spec, isStaff: false)
        #expect(!picker.laterRings.isEmpty)
        for option in picker.laterRings {
            #expect(AvatarBorder(rawValue: option.value)?.season != nil, "\(option.value) is not seasonal")
            #expect(option.label.contains(" · opens in "))
        }
        let shown = Set((picker.rings + picker.laterRings).map(\.value))
        for item in WardrobeItem.allCases where item.slot == .border {
            #expect(!shown.contains(item.value), "\(item) is shown before it is earned")
        }
    }

    @Test func anEarnedItemIsAChoice() {
        let picker = AvatarPickerContext(for: Self.spec, isStaff: false, unlocked: [.chirpFace, .stitchedRing])
        #expect(picker.faces.contains { $0.value == AvatarExpression.chirp.rawValue })
        #expect(picker.rings.contains { $0.value == AvatarBorder.stitched.rawValue })
        #expect(!picker.faces.contains { $0.value == AvatarExpression.sly.rawValue })
    }
}
