// Tests/APITests/Gamification/AccountAvatarRoutesTests.swift
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
            #expect(result.location == "/account?avatar=saved#chickadee")

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
            #expect(result.location == "/account?avatar=invalid#chickadee")
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
                    #expect(html.contains("Bird saved."))
                    #expect(html.contains("--av-border: var(--avatar-accent-orchid)"))
                    #expect(
                        html.contains(
                            #"name="backdrop" value="peach" data-av-token="--avatar-back-peach" checked"#))
                    #expect(
                        html.contains(
                            #"name="border" value="orchid" data-av-token="--avatar-accent-orchid" checked"#))
                    // The live preview is wired: the script, and the avatar it
                    // updates.
                    #expect(html.contains(#"data-avatar-picker=".bird-card .avatar-xl""#))
                    #expect(html.contains("/avatar-picker.js"))
                    // One radio per option the chokepoint accepts, in each
                    // group: the starter faces and the worn one, every
                    // backdrop, and the rings open now (a locked face or ring
                    // is not an input).
                    let spec = try await storedSpec(username: "picker_page")
                    let open: [AvatarCustomizableSlot: Int] = [
                        .expression: AvatarCustomization.options(for: .expression).filter {
                            $0 == spec.expression.rawValue || AvatarCustomization.isOpen($0, for: .expression)
                        }.count,
                        .backdrop: AvatarCustomization.options(for: .backdrop).count,
                        .border: AvatarCustomization.options(for: .border).filter {
                            $0 == spec.border.rawValue || AvatarCustomization.isOpen($0, for: .border)
                        }.count,
                    ]
                    for slot in AvatarCustomizableSlot.allCases {
                        let radios = html.components(separatedBy: #"name="\#(slot.rawValue)""#).count - 1
                        #expect(radios == open[slot], "\(slot)")
                    }
                    // Exactly one checked radio per group: face, backdrop, border.
                    #expect(html.components(separatedBy: " checked>").count - 1 == 3)
                    #expect(!html.contains("var()"), "a swatch token resolved to empty")
                })
        }
    }

    @Test func noBorderDrawsATransparentRing() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "picker_none", password: "pw", role: "student", on: app)
            _ = try await postChoices(["backdrop": "sage", "border": "none"], cookie: cookie)
            try await app.asyncTest(
                .GET, "/account",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.body.string.contains("--av-border: var(--avatar-border-none)"))
                    // The "none" radio carries the same token, so the preview
                    // matches a save.
                    #expect(
                        res.body.string.contains(
                            #"name="border" value="none" data-av-token="--avatar-border-none""#))
                    #expect(res.body.string.contains("swatch-none"))
                })
        }
    }
}
