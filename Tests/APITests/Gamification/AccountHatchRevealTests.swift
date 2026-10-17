// Tests/APITests/Gamification/AccountHatchRevealTests.swift
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

    /// The text inside each reduced-motion guard in `css`, found by matching
    /// braces, and the text outside every guard.
    private static func splitByMotionGuard(_ css: String) -> (inside: [Substring], outside: String) {
        let open = "@media (prefers-reduced-motion: no-preference) {"
        var inside: [Substring] = []
        var outside = ""
        var cursor = css.startIndex
        while let start = css.range(of: open, range: cursor..<css.endIndex) {
            outside += css[cursor..<start.lowerBound]
            var depth = 1
            var index = start.upperBound
            while index < css.endIndex, depth > 0 {
                if css[index] == "{" { depth += 1 }
                if css[index] == "}" { depth -= 1 }
                index = css.index(after: index)
            }
            inside.append(css[start.upperBound..<index])
            cursor = index
        }
        outside += css[cursor...]
        return (inside, outside)
    }

    /// The declarations of the rule for `selector` in `css`: the text between
    /// its braces, or nil when no rule starts with exactly that selector.
    private static func declarations(of selector: String, in css: some StringProtocol) -> Substring? {
        let text = String(css)
        var cursor = text.startIndex
        while let match = text.range(of: selector, range: cursor..<text.endIndex) {
            cursor = match.upperBound
            // The selector must stand alone: at a line start, before its brace.
            let before = text[text.startIndex..<match.lowerBound].last
            guard before == nil || before == "\n" || before == " " else { continue }
            let rest = text[match.upperBound...].drop { $0 == " " }
            guard rest.first == "{", let close = rest.firstIndex(of: "}") else { continue }
            return Substring(text[rest.index(after: rest.startIndex)..<close])
        }
        return nil
    }

    /// The suite owns an app, so this check runs inside `withApp` too, which
    /// shuts the app down.
    ///
    /// The egg shows, and every part of it moves, only inside the
    /// reduced-motion guard. Outside it the egg is hidden, so a reader who
    /// asked for less motion sees the bird at once.
    @Test func theEggIsOnlyForReadersWhoDidNotAskForLessMotion() async throws {
        try await withApp(app) { _ in
            let css = try String(
                contentsOf: repositoryRoot.appendingPathComponent("Public/styles.css"), encoding: .utf8)
            let (inside, outside) = Self.splitByMotionGuard(css)

            let hidden = try #require(Self.declarations(of: ".bird-hatch-egg", in: outside))
            #expect(hidden.contains("display: none"))
            let shown = try #require(
                inside.lazy.compactMap { Self.declarations(of: ".bird-hatch-egg", in: $0) }.first,
                "the egg is not shown inside the guard")
            #expect(shown.contains("display: block"))

            #expect(!outside.contains("animation: bird-hatch-"), "an egg animation runs outside the guard")
            #expect(inside.contains { $0.contains("animation: bird-hatch-wobble") })
            #expect(inside.contains { $0.contains("animation: bird-hatch-grow") })
        }
    }
}
