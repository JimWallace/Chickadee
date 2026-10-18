// Tests/APITests/EarnedToastTests.swift
//
// The Earned toast's view model and markup (docs/result-celebration.md, J2):
// the bird wears the new item, the text names it and says how it was
// earned, and Wear it is a form that saves without the script.

import Core
import Elementary
import Testing

@testable import APIServer

@Suite struct EarnedToastTests {

    private static let spec = AvatarSpec(
        cap: .ink, wing: .plain, expression: .bright, accessory: .none, accent: .ember, backdrop: .sky,
        tuft: .none, tilt: .upright, border: .none)

    @Test func aNewFaceIsWornByTheToastBird() {
        let earned = SubmissionEarnedItem(.chirpFace, wearing: Self.spec, isStaff: false)
        #expect(earned.chip == "New face")
        #expect(earned.name == "Chirp")
        #expect(earned.howEarned == "Earned by a first graded submission.")
        #expect(earned.announcement == "New face earned: Chirp.")
        #expect(earned.field == "expression")
        #expect(earned.value == "chirp")
        #expect(!earned.isRing)
        #expect(earned.ringStartDegrees == 0)
        #expect(earned.bird.expressionSymbolRef == "#av-expression-chirp")
    }

    @Test func aNewRingIsWornByTheToastBird() {
        let earned = SubmissionEarnedItem(.ouroborosRing, wearing: Self.spec, isStaff: false)
        #expect(earned.chip == "New ring")
        #expect(earned.name == "Ouroboros")
        #expect(earned.howEarned == "Earned when every test passed on a loops lab.")
        #expect(earned.field == "border")
        #expect(earned.isRing)
        #expect(earned.ringStartDegrees == 186)
        #expect(earned.bird.ringSymbolRef == "#av-ring-ouroboros")
        // The rest of the bird is the student's own.
        #expect(earned.bird.expressionSymbolRef == "#av-expression-bright")
    }

    @Test func theToastIsAHiddenStatusWithAWearItForm() {
        let earned = SubmissionEarnedItem(.twoToneRing, wearing: Self.spec, isStaff: false)
        let html = EarnedToast(page: ElementaryPageFixtures.page(), earned: earned).render()
        #expect(html.contains(#"role="status""#))
        #expect(html.contains("hidden"))
        #expect(html.contains("nb-graded nb-graded-earned is-ring"))
        #expect(html.contains(#"<form method="post" action="/account/avatar""#))
        #expect(html.contains(#"name="_csrf""#))
        #expect(html.contains(#"<input type="hidden" name="border" value="twotone">"#))
        #expect(html.contains(##"data-wear-ring="#av-ring-twotone""##))
        #expect(html.contains(#"data-wear-face="""#))
        #expect(html.contains("Wear it"))
        #expect(html.contains("Not now"))
    }
}
