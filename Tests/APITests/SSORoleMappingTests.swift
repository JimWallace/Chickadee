import Fluent
import XCTest

@testable import chickadee_server

final class SSORoleMappingTests: XCTestCase {

    private let routes = SSOAuthRoutes()

    func testNoAllowlistsReturnsNil() {
        let role = routes.mappedSSORole(
            username: "alice",
            userIdentifier: "alice123",
            email: "alice@example.edu",
            adminAllowlist: [],
            instructorAllowlist: []
        )
        XCTAssertNil(role)
    }

    func testAdminAllowlistMatchesUsernameCaseInsensitive() {
        let role = routes.mappedSSORole(
            username: "Alice",
            userIdentifier: "alice123",
            email: "alice@example.edu",
            adminAllowlist: ["alice"],
            instructorAllowlist: []
        )
        XCTAssertEqual(role, "admin")
    }

    func testInstructorAllowlistMatchesUserIdentifierWhenNotAdmin() {
        let role = routes.mappedSSORole(
            username: "bob",
            userIdentifier: "B12345",
            email: "bob@example.edu",
            adminAllowlist: [],
            instructorAllowlist: ["b12345"]
        )
        XCTAssertEqual(role, "instructor")
    }

    func testAdminAllowlistBeatsInstructorAllowlist() {
        let role = routes.mappedSSORole(
            username: "carol",
            userIdentifier: "c999",
            email: "carol@example.edu",
            adminAllowlist: ["carol@example.edu"],
            instructorAllowlist: ["carol", "c999"]
        )
        XCTAssertEqual(role, "admin")
    }

    func testBlankValuesAreIgnored() {
        let role = routes.mappedSSORole(
            username: "   ",
            userIdentifier: "   ",
            email: "Instructor@example.edu ",
            adminAllowlist: [],
            instructorAllowlist: ["instructor@example.edu"]
        )
        XCTAssertEqual(role, "instructor")
    }
}
