// Tests/APITests/AccountHatchRevealTests.swift
//
// The new bird comes out of its egg on the first page after a hatch (#2590).
// The egg is markup over the hero bird, and the stylesheet keeps it to
// readers who did not ask for less motion.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class AccountHatchRevealTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-hatch-reveal")
    }

    /// Logs in a fresh student, draws their bird and hatches a new one.
    private func hatchedStudent(_ username: String) async throws -> String {
        let cookie = try await loginUser(username: username, password: "pw", role: "student", on: app)
        _ = try await getHTML("/account", cookie: cookie, on: app)
        let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var location: String?
        try await app.asyncTest(
            .POST, "/account/avatar/hatch",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: newCookie)
                try req.content.encode(["_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in location = res.headers.first(name: .location) })
        #expect(location == "/account?avatar=hatched#bird")
        return newCookie
    }

    @Test func theFirstPageAfterAHatchShowsTheEgg() async throws {
        try await withApp(app) { _ in
            let cookie = try await hatchedStudent("reveal_hatched")
            let html = try await getHTML("/account?avatar=hatched", cookie: cookie, on: app)
            let reveal = try #require(html.range(of: "class=\"bird-hatch\""), "no reveal")
            let rest = html[reveal.upperBound...]
            // The hero bird sits inside the reveal, before the egg over it.
            let bird = try #require(rest.range(of: "avatar avatar-xl"))
            let egg = try #require(rest.range(of: "class=\"bird-hatch-egg\" aria-hidden=\"true\""))
            #expect(bird.lowerBound < egg.lowerBound)
            #expect(rest.contains("bird-hatch-shell bird-hatch-shell--top"))
            #expect(rest.contains("bird-hatch-shell bird-hatch-shell--bottom"))
            #expect(html.components(separatedBy: "class=\"bird-hatch\"").count == 2)
        }
    }

    @Test func anOrdinaryLoadShowsNoEgg() async throws {
        try await withApp(app) { _ in
            let cookie = try await hatchedStudent("reveal_plain")
            let html = try await getHTML("/account", cookie: cookie, on: app)
            #expect(!html.contains("bird-hatch"))
            #expect(html.contains("avatar avatar-xl"))
        }
    }

    @Test func goingBackShowsNoEgg() async throws {
        try await withApp(app) { _ in
            let cookie = try await hatchedStudent("reveal_back")
            let html = try await getHTML("/account?avatar=restored", cookie: cookie, on: app)
            #expect(!html.contains("bird-hatch"))
        }
    }

    /// The suite owns an app, so this check runs inside `withApp` too, which
    /// shuts the app down.
    ///
    /// The egg is shown only inside the reduced-motion guard: outside it, the
    /// egg is `display: none`, so a reader who asked for less motion sees the
    /// bird at once.
    @Test func theEggIsOnlyForReadersWhoDidNotAskForLessMotion() async throws {
        try await withApp(app) { _ in
            let css = try String(
                contentsOf: repositoryRoot.appendingPathComponent("Public/styles.css"), encoding: .utf8)
            #expect(css.contains(".bird-hatch-egg { display: none; }"))
            let guardOpen = "@media (prefers-reduced-motion: no-preference) {\n    .bird-hatch-egg {"
            let guarded = try #require(css.range(of: guardOpen), "the egg is not shown inside the guard")
            #expect(css[guarded.upperBound...].prefix(200).contains("display: block;"))
            #expect(css.components(separatedBy: "animation: bird-hatch-").count - 1 == 4)
        }
    }
}
