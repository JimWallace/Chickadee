// Tests/CoreTests/Gamification/AvatarCapDisplayNameTests.swift
//
// `AvatarCap.displayName` is the colour name that a student reads in the
// avatar picker. It is the raw value, capitalized.

import Core
import Testing

@Suite struct AvatarCapDisplayNameTests {

    @Test func displayNameCapitalizesTheRawValue() {
        #expect(AvatarCap.slate.displayName == "Slate")
        #expect(AvatarCap.graphite.displayName == "Graphite")
    }

    @Test func everyCapHasADistinctCapitalizedName() {
        let names = AvatarCap.allCases.map(\.displayName)
        #expect(names.allSatisfy { $0.first?.isUppercase == true })
        #expect(Set(names).count == AvatarCap.allCases.count)
    }
}
