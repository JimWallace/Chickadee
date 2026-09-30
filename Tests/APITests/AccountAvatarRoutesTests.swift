// Tests/APITests/AccountAvatarRoutesTests.swift
//
// The account page's Chickadee picker (docs/student-wardrobe.md, W1):
//   POST /account/avatar — set the backdrop and the border
// and the one-time swap of drawn gradcaps for the headband.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AccountAvatarRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-acct-avatar")
    }

    private func storedSpec(username: String) async throws -> AvatarSpec {
        let user = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == username).first())
        return try #require(user.avatarSpecJSON.flatMap(AvatarStore.decode))
    }

    /// Posts the picker form and returns the status and the redirect target.
    private func postChoices(
        _ fields: [String: String], cookie: String
    ) async throws
        -> (status: HTTPStatus, location: String?)
    {
        let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var body = fields
        body["_csrf"] = token
        var status: HTTPStatus = .internalServerError
        var location: String?
        try await app.asyncTest(
            .POST, "/account/avatar",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: newCookie)
                try req.content.encode(body, as: .urlEncodedForm)
            },
            afterResponse: { res in
                status = res.status
                location = res.headers.first(name: .location)
            })
        return (status, location)
    }

    // MARK: - Saving

    @Test func savingSetsTheBackdropAndBorderAndNothingElse() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "picker_save", password: "pw", role: "student", on: app)
            // The first account view draws the bird.
            try await app.asyncTest(
                .GET, "/account",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.status == .ok) })
            let before = try await storedSpec(username: "picker_save")

            let result = try await postChoices(["backdrop": "lilac", "border": "moss"], cookie: cookie)
            #expect(result.status == .seeOther)
            #expect(result.location == "/account?avatar=saved")

            let after = try await storedSpec(username: "picker_save")
            #expect(after.backdrop == .lilac)
            #expect(after.border == .moss)
            var expected = before
            expected.backdrop = .lilac
            expected.border = .moss
            #expect(after == expected, "a slot other than the two chosen changed")
        }
    }

    @Test func aRefusedChoiceChangesNothing() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "picker_bad", password: "pw", role: "student", on: app)
            _ = try await postChoices(["backdrop": "sky", "border": "none"], cookie: cookie)
            let before = try await storedSpec(username: "picker_bad")

            // A valid backdrop beside an invalid border: neither is applied.
            let result = try await postChoices(["backdrop": "rose", "border": "gold"], cookie: cookie)
            #expect(result.status == .seeOther)
            #expect(result.location == "/account?avatar=invalid")
            #expect(try await storedSpec(username: "picker_bad") == before)
        }
    }

    @Test func thePageShowsTheSavedChoicesAndTheRing() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "picker_page", password: "pw", role: "student", on: app)
            _ = try await postChoices(["backdrop": "peach", "border": "orchid"], cookie: cookie)

            try await app.asyncTest(
                .GET, "/account?avatar=saved",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Chickadee saved."))
                    #expect(html.contains("--av-border: var(--avatar-accent-orchid)"))
                    #expect(html.contains(#"name="backdrop" value="peach" checked"#))
                    #expect(html.contains(#"name="border" value="orchid" checked"#))
                    // One radio per option the chokepoint accepts, in each group.
                    for slot in AvatarCustomizableSlot.allCases {
                        let radios = html.components(separatedBy: #"name="\#(slot.rawValue)""#).count - 1
                        #expect(radios == AvatarCustomization.options(for: slot).count, "\(slot)")
                    }
                    // Exactly one checked radio per group.
                    #expect(html.components(separatedBy: " checked>").count - 1 == 2)
                    #expect(!html.contains("var()"), "a swatch token resolved to empty")
                })
        }
    }

    @Test func noBorderDrawsTheRingInTheBackdropColour() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "picker_none", password: "pw", role: "student", on: app)
            _ = try await postChoices(["backdrop": "sage", "border": "none"], cookie: cookie)
            try await app.asyncTest(
                .GET, "/account",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.body.string.contains("--av-border: var(--avatar-back-sage)"))
                    #expect(res.body.string.contains("swatch-none"))
                })
        }
    }

    // MARK: - The gradcap swap

    @Test func theMigrationSwapsOnlyDrawnGradcaps() async throws {
        try await withApp(app) { _ in
            let withCap = try await makeTestStudent(on: app, username: "swap_cap")
            let capSpec = AvatarSpec(
                cap: .plum, wing: .barred, expression: .wink, accessory: .gradcap, accent: .honey,
                backdrop: .rose, tuft: .crest, tilt: .left, border: .moss)
            withCap.avatarSpecJSON = AvatarStore.encode(capSpec)
            try await withCap.save(on: app.db)

            let without = try await makeTestStudent(on: app, username: "swap_scarf")
            var scarfSpec = capSpec
            scarfSpec.accessory = .scarf
            without.avatarSpecJSON = AvatarStore.encode(scarfSpec)
            try await without.save(on: app.db)

            try await SwapStarterGradcapForHeadband().prepare(on: app.db)

            var expected = capSpec
            expected.accessory = .headband
            #expect(try await storedSpec(username: "swap_cap") == expected)
            #expect(try await storedSpec(username: "swap_scarf") == scarfSpec)
        }
    }
}
