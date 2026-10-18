// Tests/APITests/AccountPreferredNameRowTests.swift
//
// The account page shows the preferred name in its own row only when the
// heading does not already show it (`accountPreferredNameRow`).

import Testing

@testable import APIServer

@Suite struct AccountPreferredNameRowTests {

    @Test func aPreferredNameThatDiffersFromTheHeadingShows() {
        #expect(accountPreferredNameRow(preferredName: "Avery", identityName: "Avery Sandoval") == "Avery")
    }

    @Test func aPreferredNameThatIsTheHeadingDoesNotShowTwice() {
        #expect(accountPreferredNameRow(preferredName: "Avery", identityName: "Avery") == nil)
    }

    @Test func noPreferredNameOnFileShowsNoRow() {
        #expect(accountPreferredNameRow(preferredName: nil, identityName: "a4student") == nil)
        #expect(accountPreferredNameRow(preferredName: "   ", identityName: "a4student") == nil)
    }

    @Test func surroundingSpaceIsTrimmed() {
        #expect(accountPreferredNameRow(preferredName: " Avery ", identityName: "Avery Sandoval") == "Avery")
        #expect(accountPreferredNameRow(preferredName: " Avery ", identityName: "Avery") == nil)
    }
}
