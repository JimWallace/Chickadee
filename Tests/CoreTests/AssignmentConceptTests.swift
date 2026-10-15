// Tests/CoreTests/AssignmentConceptTests.swift
//
// The concept rings' unlock rule (docs/student-wardrobe.md, "Concept
// rings"): full marks on an assignment tagged with a concept earn that
// concept's ring. An untagged assignment earns no concept ring.

import Testing

@testable import Core

@Suite struct AssignmentConceptTests {

    private static func graded(
        _ assignment: String, concept: AssignmentConcept?, pass: Int, of total: Int
    ) -> WardrobeProgress.Graded {
        WardrobeProgress.Graded(
            assignmentID: assignment, attemptNumber: 2, passCount: pass, totalTests: total, concept: concept)
    }

    private static let conceptItems: Set<WardrobeItem> = Set(AssignmentConcept.allCases.map(WardrobeItem.init))

    /// The stored raw values are the storage format: they must not change.
    @Test func theStoredRawValuesAreFixed() {
        #expect(
            AssignmentConcept.allCases.map(\.rawValue)
                == ["numbers", "conditionals", "loops", "functions", "binary", "healthData"])
    }

    @Test func eachConceptHasItsOwnRingAndName() {
        #expect(
            AssignmentConcept.allCases.map(\.ring) == [.lifering, .greenlight, .ouroboros, .function, .binary, .pulse])
        #expect(
            AssignmentConcept.allCases.map(\.displayName)
                == ["Variables & numbers", "Conditionals", "Loops", "Functions", "Data representation", "Health data"])
    }

    /// Each concept has one item, the item opens the concept's ring, and the
    /// item knows its concept.
    @Test(arguments: AssignmentConcept.allCases)
    func eachConceptHasOneItemForItsRing(concept: AssignmentConcept) {
        let item = WardrobeItem(concept: concept)
        #expect(item.slot == .border)
        #expect(item.value == concept.ring.rawValue)
        #expect(item.rawValue == "border.\(concept.ring.rawValue)")
        #expect(item.concept == concept)
        #expect(WardrobeItem(slot: .border, value: concept.ring.rawValue) == item)
    }

    @Test func theRingPhraseDoesNotRepeatRing() {
        #expect(AssignmentConcept.loops.ringPhrase == "the Ouroboros ring")
        #expect(AssignmentConcept.numbers.ringPhrase == "the Life ring")
        #expect(AssignmentConcept.conditionals.ringPhrase == "the Green light ring")
    }

    @Test func theHowToEarnTextNamesTheConcept() {
        #expect(WardrobeItem.ouroborosRing.howToEarn == "when every test passes on a loops lab")
        #expect(WardrobeItem.lifeRing.howToEarn == "when every test passes on a variables & numbers lab")
        #expect(WardrobeItem.pulseRing.howToEarn == "when every test passes on a health data lab")
    }

    /// One test per ring: full marks on a tagged assignment earn its ring, and
    /// only its ring.
    @Test(arguments: AssignmentConcept.allCases)
    func fullMarksOnATaggedAssignmentEarnsItsRing(concept: AssignmentConcept) {
        let progress = WardrobeProgress(graded: [Self.graded("a", concept: concept, pass: 3, of: 3)])
        #expect(progress.fullMarksConcepts == [concept])
        #expect(WardrobeItem.earned(by: progress).intersection(Self.conceptItems) == [WardrobeItem(concept: concept)])
    }

    @Test(arguments: AssignmentConcept.allCases)
    func lessThanFullMarksEarnsNoRing(concept: AssignmentConcept) {
        let progress = WardrobeProgress(graded: [Self.graded("a", concept: concept, pass: 2, of: 3)])
        #expect(WardrobeItem.earned(by: progress).isDisjoint(with: Self.conceptItems))
    }

    @Test func anUntaggedAssignmentEarnsNoConceptRing() {
        let progress = WardrobeProgress(graded: [Self.graded("a", concept: nil, pass: 3, of: 3)])
        #expect(progress.fullMarksConcepts.isEmpty)
        #expect(WardrobeItem.earned(by: progress).isDisjoint(with: Self.conceptItems))
    }

    /// Two assignments share a concept: full marks on either one earns it.
    @Test func aSharedConceptIsEarnedByEitherAssignment() {
        for winner in ["a", "b"] {
            let progress = WardrobeProgress(graded: [
                Self.graded("a", concept: .loops, pass: winner == "a" ? 2 : 1, of: 2),
                Self.graded("b", concept: .loops, pass: winner == "b" ? 2 : 1, of: 2),
            ])
            #expect(WardrobeItem.earned(by: progress).contains(.ouroborosRing), "\(winner)")
        }
    }

    @Test func anEarnedConceptRingIsOpenOnlyToItsEarner() {
        #expect(!AvatarCustomization.isOpen("ouroboros", for: .border))
        #expect(AvatarCustomization.isOpen("ouroboros", for: .border, unlocked: [.ouroborosRing]))
        #expect(!AvatarCustomization.isOpen("pulse", for: .border, unlocked: [.ouroborosRing]))
    }
}
