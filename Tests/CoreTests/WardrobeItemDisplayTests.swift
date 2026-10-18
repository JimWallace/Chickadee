// Tests/CoreTests/WardrobeItemDisplayTests.swift
//
// What the result page's Earned toast says about an item
// (docs/result-celebration.md, J2): its name and how it was earned, and
// where a new ring starts to draw in.

import Testing

@testable import Core

@Suite struct WardrobeItemDisplayTests {

    @Test func eachItemHasThePickersName() {
        #expect(WardrobeItem.chirpFace.displayName == "Chirp")
        #expect(WardrobeItem.twoToneRing.displayName == "Two-tone")
        #expect(WardrobeItem.lifeRing.displayName == "Life ring")
        #expect(WardrobeItem.pulseRing.displayName == "Pulse")
        for item in WardrobeItem.allCases {
            #expect(!item.displayName.isEmpty)
            #expect(item.displayName != item.value || item.slot == .backdrop, "\(item) has no display name")
        }
    }

    @Test func howEachItemWasEarnedIsInThePastTense() {
        #expect(WardrobeItem.chirpFace.howEarned == "by a first graded submission")
        #expect(WardrobeItem.stitchedRing.howEarned == "for a comeback on three assignments")
        #expect(WardrobeItem.pulseRing.howEarned == "when every test passed on a health data lab")
    }

    /// The snake of the ouroboros draws in from its head; every other ring
    /// from the top.
    @Test func aRingDrawsInFromItsOwnStart() {
        #expect(AvatarRing.ouroboros.drawStartDegrees == 186)
        for ring in AvatarRing.allCases where ring != .ouroboros {
            #expect(ring.drawStartDegrees == 0, "\(ring)")
        }
    }
}
