import XCTest
@testable import chickadee_server

final class AuthModeResolutionTests: XCTestCase {
    func testDefaultsToSSOWhenUnset() {
        XCTAssertEqual(
            resolvedAuthMode(requestedMode: nil, nonSSOModesEnabled: false),
            .sso
        )
    }

    func testKeepsSSOWhenRequested() {
        XCTAssertEqual(
            resolvedAuthMode(requestedMode: .sso, nonSSOModesEnabled: false),
            .sso
        )
    }

    func testHidesLocalWhenFlagDisabled() {
        XCTAssertEqual(
            resolvedAuthMode(requestedMode: .local, nonSSOModesEnabled: false),
            .sso
        )
    }

    func testHidesDualWhenFlagDisabled() {
        XCTAssertEqual(
            resolvedAuthMode(requestedMode: .dual, nonSSOModesEnabled: false),
            .sso
        )
    }

    func testAllowsLocalWhenFlagEnabled() {
        XCTAssertEqual(
            resolvedAuthMode(requestedMode: .local, nonSSOModesEnabled: true),
            .local
        )
    }

    func testAllowsDualWhenFlagEnabled() {
        XCTAssertEqual(
            resolvedAuthMode(requestedMode: .dual, nonSSOModesEnabled: true),
            .dual
        )
    }
}
