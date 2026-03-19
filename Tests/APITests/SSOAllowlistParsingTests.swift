import XCTest
@testable import chickadee_server

final class SSOAllowlistParsingTests: XCTestCase {

    func testNilInputReturnsEmptySet() {
        let parsed = parseSSOIdentityAllowlist(nil)
        XCTAssertTrue(parsed.isEmpty)
    }

    func testSeparatorsAndWhitespaceAndCaseAreNormalized() {
        let raw = " Alice ,BOB;\ncarol@example.edu ;  "
        let parsed = parseSSOIdentityAllowlist(raw)
        XCTAssertEqual(parsed, ["alice", "bob", "carol@example.edu"])
    }

    func testEmptyAndWhitespaceEntriesAreDropped() {
        let raw = " ,  ; \n ;dave"
        let parsed = parseSSOIdentityAllowlist(raw)
        XCTAssertEqual(parsed, ["dave"])
    }
}

