// Tests/CoreTests/WardrobeItemTests.swift
//
// The wardrobe items a student earns by their work (#2592): the rule for
// each, the slot and value each opens, and the customization checkpoint
// opening an earned item to the student who earned it only.

import Testing

@testable import Core

@Suite struct WardrobeItemTests {

    private static let base = AvatarSpec(
        cap: .teal, wing: .barred, expression: .wink, accessory: .scarf, accent: .honey,
        backdrop: .rose, tuft: .crest, tilt: .left, border: .moss)

    private static func graded(
        _ assignment: String, attempt: Int = 2, pass: Int, of total: Int
    ) -> WardrobeProgress.Graded {
        WardrobeProgress.Graded(assignmentID: assignment, attemptNumber: attempt, passCount: pass, totalTests: total)
    }

    /// The stored raw values are the storage format: they must not change.
    @Test func theStoredRawValuesAreFixed() {
        #expect(
            WardrobeItem.allCases.map(\.rawValue) == [
                "expression.chirp", "expression.sly", "border.twotone", "expression.dreamy", "border.stitched",
            ])
    }

    @Test(arguments: WardrobeItem.allCases)
    func eachItemOpensOneExistingOption(item: WardrobeItem) {
        #expect(AvatarCustomization.options(for: item.slot).contains(item.value))
        #expect(WardrobeItem(slot: item.slot, value: item.value) == item)
        #expect(!item.howToEarn.isEmpty)
    }

    @Test func noWorkEarnsNothing() {
        #expect(WardrobeItem.earned(by: WardrobeProgress(graded: [])).isEmpty)
    }

    @Test func aFirstGradedSubmissionEarnsTheChirpFace() {
        let progress = WardrobeProgress(graded: [Self.graded("a", pass: 0, of: 4)])
        #expect(WardrobeItem.earned(by: progress) == [.chirpFace])
    }

    @Test func fullMarksOnAFirstTryEarnsTheSlyFace() {
        let firstTry = WardrobeProgress(graded: [Self.graded("a", attempt: 1, pass: 4, of: 4)])
        #expect(WardrobeItem.earned(by: firstTry) == [.chirpFace, .slyFace])
        // Full marks on a later attempt, or a first attempt short of full
        // marks, is not a first try.
        let later = WardrobeProgress(graded: [
            Self.graded("a", attempt: 1, pass: 3, of: 4), Self.graded("a", attempt: 2, pass: 4, of: 4),
        ])
        #expect(!WardrobeItem.earned(by: later).contains(.slyFace))
    }

    @Test func fullMarksOnThreeAssignmentsEarnsTheTwoToneRing() {
        let two = WardrobeProgress(graded: [
            Self.graded("a", pass: 2, of: 2), Self.graded("b", pass: 2, of: 2), Self.graded("b", pass: 3, of: 3),
        ])
        #expect(two.fullMarksAssignments == 2)
        #expect(!WardrobeItem.earned(by: two).contains(.twoToneRing))
        let three = WardrobeProgress(graded: [
            Self.graded("a", pass: 2, of: 2), Self.graded("b", pass: 2, of: 2), Self.graded("c", pass: 5, of: 5),
        ])
        #expect(WardrobeItem.earned(by: three).contains(.twoToneRing))
    }

    /// A result with no tests passes nothing, so it is never full marks.
    @Test func aResultWithNoTestsIsNotFullMarks() {
        #expect(!Self.graded("a", attempt: 1, pass: 0, of: 0).isFullMarks)
        let progress = WardrobeProgress(graded: [Self.graded("a", attempt: 1, pass: 0, of: 0)])
        #expect(WardrobeItem.earned(by: progress) == [.chirpFace])
    }

    @Test func anEarnedItemIsOpenOnlyToTheStudentWhoEarnedIt() throws {
        #expect(!AvatarCustomization.isOpen("chirp", for: .expression))
        #expect(AvatarCustomization.isOpen("chirp", for: .expression, unlocked: [.chirpFace]))
        #expect(!AvatarCustomization.isOpen("sly", for: .expression, unlocked: [.chirpFace]))
        #expect(AvatarCustomization.isOpen("twotone", for: .border, unlocked: [.twoToneRing]))
        #expect(AvatarCustomization.isOpen("dreamy", for: .expression, unlocked: [.dreamyFace]))
        #expect(AvatarCustomization.isOpen("stitched", for: .border, unlocked: [.stitchedRing]))
        // An item no rule earns stays locked whatever is unlocked.
        let everything = Set(WardrobeItem.allCases)
        #expect(!AvatarCustomization.isOpen("spectrum", for: .border, unlocked: everything))

        let updated = try AvatarCustomization.applying(
            ["expression": "chirp", "border": "twotone"], to: Self.base, isStaff: false,
            unlocked: [.chirpFace, .twoToneRing])
        #expect(updated.expression == .chirp)
        #expect(updated.border == .twotone)
        #expect(throws: AvatarCustomizationError.optionLocked(slot: .expression, value: "sly")) {
            try AvatarCustomization.applying(
                ["expression": "sly"], to: Self.base, isStaff: false, unlocked: [.chirpFace])
        }
    }

    /// Staff wear the staff ring: an earned ring does not change that.
    @Test func staffCannotChooseAnEarnedRing() {
        #expect(throws: AvatarCustomizationError.staffRingIsFixed) {
            try AvatarCustomization.applying(
                ["border": "twotone"], to: Self.base, isStaff: true, unlocked: [.twoToneRing])
        }
    }
}
