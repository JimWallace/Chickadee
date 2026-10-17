import Fluent
import Testing

@testable import APIServer

@Suite struct SSORoleMappingTests {

    private let routes = SSOAuthRoutes(configuredCallbackPath: "/auth/sso/callback")

    @Test func noAdminAllowlistReturnsNil() {
        let role = routes.mappedSSORole(
            username: "alice",
            userIdentifier: "alice123",
            email: "alice@example.edu",
            adminAllowlist: []
        )
        #expect(role == nil)
    }

    @Test func adminAllowlistMatchesUsernameCaseInsensitive() {
        let role = routes.mappedSSORole(
            username: "Alice",
            userIdentifier: "alice123",
            email: "alice@example.edu",
            adminAllowlist: ["alice"]
        )
        #expect(role == "admin")
    }

    @Test func adminAllowlistMatchesUserIdentifier() {
        let role = routes.mappedSSORole(
            username: "bob",
            userIdentifier: "B12345",
            email: "bob@example.edu",
            adminAllowlist: ["b12345"]
        )
        #expect(role == "admin")
    }

    @Test func adminAllowlistMatchesEmail() {
        let role = routes.mappedSSORole(
            username: "carol",
            userIdentifier: "c999",
            email: "carol@example.edu",
            adminAllowlist: ["carol@example.edu"]
        )
        #expect(role == "admin")
    }

    /// Instructor authority is per-course as of Phase 5 — SSO never assigns an
    /// instructor (or any non-admin) role; a non-match returns nil so the caller
    /// leaves the existing role untouched / defaults a new user to student.
    @Test func nonAdminMatchReturnsNil() {
        let role = routes.mappedSSORole(
            username: "dave",
            userIdentifier: "d111",
            email: "dave@example.edu",
            adminAllowlist: ["someone-else"]
        )
        #expect(role == nil)
    }

    @Test func blankValuesAreIgnored() {
        let role = routes.mappedSSORole(
            username: "   ",
            userIdentifier: "   ",
            email: "Admin@example.edu ",
            adminAllowlist: ["admin@example.edu"]
        )
        #expect(role == "admin")
    }
}
