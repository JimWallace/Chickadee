import Fluent
import Testing

@testable import APIServer

@Suite struct SSORoleMappingTests {

    private let routes = SSOAuthRoutes(configuredCallbackPath: "/auth/sso/callback")

    @Test func noAllowlistsReturnsNil() {
        let role = routes.mappedSSORole(
            username: "alice",
            userIdentifier: "alice123",
            email: "alice@example.edu",
            adminAllowlist: [],
            instructorAllowlist: []
        )
        #expect(role == nil)
    }

    @Test func adminAllowlistMatchesUsernameCaseInsensitive() {
        let role = routes.mappedSSORole(
            username: "Alice",
            userIdentifier: "alice123",
            email: "alice@example.edu",
            adminAllowlist: ["alice"],
            instructorAllowlist: []
        )
        #expect(role == "admin")
    }

    @Test func instructorAllowlistMatchesUserIdentifierWhenNotAdmin() {
        let role = routes.mappedSSORole(
            username: "bob",
            userIdentifier: "B12345",
            email: "bob@example.edu",
            adminAllowlist: [],
            instructorAllowlist: ["b12345"]
        )
        #expect(role == "instructor")
    }

    @Test func adminAllowlistBeatsInstructorAllowlist() {
        let role = routes.mappedSSORole(
            username: "carol",
            userIdentifier: "c999",
            email: "carol@example.edu",
            adminAllowlist: ["carol@example.edu"],
            instructorAllowlist: ["carol", "c999"]
        )
        #expect(role == "admin")
    }

    @Test func blankValuesAreIgnored() {
        let role = routes.mappedSSORole(
            username: "   ",
            userIdentifier: "   ",
            email: "Instructor@example.edu ",
            adminAllowlist: [],
            instructorAllowlist: ["instructor@example.edu"]
        )
        #expect(role == "instructor")
    }
}
