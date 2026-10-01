// Tests/CoreTests/AvatarSizeTests.swift
//
// The avatar sizes a template can ask for, and the class each one maps to.

import Testing

@testable import Core

@Suite struct AvatarSizeTests {

    @Test func everySizeMapsToItsOwnStylesheetClass() {
        #expect(AvatarSize.roster.cssClass == "avatar avatar-md")
        #expect(AvatarSize.hero.cssClass == "avatar avatar-lg")
        #expect(AvatarSize.podium.cssClass == "avatar avatar-xl")
        let classes = AvatarSize.allCases.map(\.cssClass)
        #expect(Set(classes).count == classes.count)
    }

    @Test func aPresentationCarriesTheSizeClass() {
        let spec = AvatarSpec.drawn(fromSeed: 1)
        let hero = AvatarPresentation(for: spec, size: .hero, accessibility: .decorative)
        #expect(hero.sizeClass == "avatar avatar-lg")
    }
}
