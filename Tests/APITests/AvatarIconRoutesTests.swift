// Tests/APITests/AvatarIconRoutesTests.swift
//
// The tab icon route and the head tags that point at it
// (docs/student-avatars.md, "The tab icon").

import Core
import Elementary
import Testing
import VaporTesting

@testable import APIServer

@Suite struct AvatarIconRoutesTests {
    private static let gentleFern = AvatarSpec(
        cap: .teal, wing: .barred, expression: .bright, accessory: .scarf, accent: .honey,
        backdrop: .sky, tuft: .cowlick)

    /// The route behind the security headers, as production wires it, with no
    /// session and no database.
    private func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.middleware.use(SecurityHeadersMiddleware())
        try app.register(collection: AvatarIconRoutes(renderer: app.avatarIconRenderer()))
        return app
    }

    // MARK: - The route

    @Test func anIconCarriesItsHeaders() async throws {
        try await withApp(try await makeApp()) { app in
            let path = AvatarIconKey.path(version: "0.0.0", key: AvatarIconKey.encode(Self.gentleFern))
            try await app.asyncTest(.GET, path) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentType) == "image/svg+xml")
                #expect(res.headers.first(name: "X-Content-Type-Options") == "nosniff")
                #expect(res.headers.first(name: .cacheControl) == "public, max-age=31536000, immutable")
                #expect(
                    res.headers.first(name: "Content-Security-Policy")
                        == "default-src 'none'; style-src 'unsafe-inline'")
                #expect(res.body.string.hasPrefix("<svg"))
            }
        }
    }

    @Test func aSecondRequestReturnsTheSameBytes() async throws {
        try await withApp(try await makeApp()) { app in
            let path = AvatarIconKey.path(version: "0.0.0", key: AvatarIconKey.encode(Self.gentleFern))
            var first = ""
            try await app.asyncTest(.GET, path) { res async in first = res.body.string }
            try await app.asyncTest(.GET, path) { res async in
                #expect(!first.isEmpty)
                #expect(res.body.string == first)
            }
        }
    }

    @Test(arguments: [
        "/avatar-icon/0.0.0/chickadee.ink.plain.bright.none.none.lagoon.night.svg",
        "/avatar-icon/0.0.0/robin.ink.plain.bright.none.none.lagoon.aqua.svg",
        "/avatar-icon/0.0.0/chickadee.ink.plain.bright.none.none.lagoon.aqua.png",
        "/avatar-icon/0.0.0/chickadee.ink.plain.bright.none.none.lagoon.aqua",
    ])
    func aBadKeyIsNotFound(path: String) async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(.GET, path) { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test func faviconSVGIsTheHouseBird() async throws {
        try await withApp(try await makeApp()) { app in
            var house = ""
            try await app.asyncTest(.GET, AvatarIconKey.path(version: "0.0.0", key: AvatarIconKey.house)) { res async in
                house = res.body.string
            }
            try await app.asyncTest(.GET, "/favicon.svg") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentType) == "image/svg+xml")
                #expect(res.headers.first(name: .cacheControl) == "public, max-age=86400")
                #expect(!house.isEmpty)
                #expect(res.body.string == house)
            }
        }
    }

    // MARK: - The head tags

    private func page(user: CurrentUserContext?) -> PageRequestContext {
        PageRequestContext(
            currentUser: user, csrfToken: "t", appVersion: "1.2.3",
            sessionIdleTimeoutSeconds: 0, sessionIdleWarningSeconds: 0, iconSprite: "")
    }

    private func user(bird: AvatarSpec?, teaches: Bool = false) -> CurrentUserContext {
        let user = APIUser(username: "gentle", passwordHash: "", role: UserRole.user.rawValue)
        user.avatarSpecJSON = bird.flatMap(AvatarStore.encode)
        let course = CourseContext(
            id: "c1", code: "CS135", name: "Design", isActive: true, role: teaches ? .instructor : .student,
            termLabel: nil, termShortLabel: nil, urlKey: "CS135")
        return CurrentUserContext(user: user, activeCourse: course, enrolledCourses: [course])
    }

    private func svgIconHref(in html: String) -> String? {
        html.firstMatch(of: /<link rel="icon" type="image\/svg\+xml" href="([^"]+)">/).map { String($0.1) }
    }

    private let housePath = AvatarIconKey.path(version: "1.2.3", key: AvatarIconKey.house)

    @Test func aSignedOutPageShowsTheHouseBird() {
        let html = BaseLayout(title: "T", page: page(user: nil)) { div {} }.render()
        #expect(svgIconHref(in: html) == housePath)
        #expect(html.contains(#"<link rel="icon" href="/favicon.ico?v=1.2.3" sizes="32x32">"#))
        #expect(html.contains(#"<link rel="apple-touch-icon" href="/apple-touch-icon.png?v=1.2.3">"#))
        #expect(!html.contains("favicon.png"))
    }

    @Test func aSignedInPageShowsTheViewersOwnBird() {
        let html = BaseLayout(title: "T", page: page(user: user(bird: Self.gentleFern))) { div {} }.render()
        #expect(
            svgIconHref(in: html) == AvatarIconKey.path(version: "1.2.3", key: AvatarIconKey.encode(Self.gentleFern)))
    }

    @Test func staffGetTheirOwnBirdWithNoRingInTheKey() {
        let staff = user(bird: Self.gentleFern, teaches: true)
        #expect(staff.tabIconKey == AvatarIconKey.encode(Self.gentleFern))
        #expect(staff.navAvatar?.ringSymbolRef == "#av-ring-staff")
    }

    @Test func aUserWithNoBirdYetShowsTheHouseBird() {
        let html = BaseLayout(title: "T", page: page(user: user(bird: nil))) { div {} }.render()
        #expect(svgIconHref(in: html) == housePath)
    }

    @Test func anEmbeddedPageShowsTheHouseBird() {
        let html = BaseLayout(title: "T", page: page(user: user(bird: Self.gentleFern)), embedded: true) {
            div {}
        }.render()
        #expect(svgIconHref(in: html) == housePath)
    }

    @Test func presentModeShowsTheHouseBird() {
        let html = PresentLayout(title: "T", page: page(user: user(bird: Self.gentleFern))) { div {} }.render()
        #expect(svgIconHref(in: html) == housePath)
        #expect(!html.contains("favicon.png"))
    }
}
