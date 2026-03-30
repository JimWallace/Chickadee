import Testing
@testable import chickadee_server

@Suite struct SSOAllowlistParsingTests {

    @Test func nilInputReturnsEmptySet() {
        #expect(parseSSOIdentityAllowlist(nil).isEmpty)
    }

    @Test func separatorsAndWhitespaceAndCaseAreNormalized() {
        let raw = " Alice ,BOB;\ncarol@example.edu ;  "
        #expect(parseSSOIdentityAllowlist(raw) == ["alice", "bob", "carol@example.edu"])
    }

    @Test func emptyAndWhitespaceEntriesAreDropped() {
        let raw = " ,  ; \n ;dave"
        #expect(parseSSOIdentityAllowlist(raw) == ["dave"])
    }
}
