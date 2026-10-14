// Tests/APITests/AccountSpeciesPickerTests.swift
//
// The Colour group of the account page's "Your bird" card: the species is
// drawn, not chosen. POST /account/avatar with `cap` changes the colourway only
// within the student's own species, refuses another species' colourway, and
// the page offers exactly the own species' colourways with the data the live
// preview needs.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AccountSpeciesPickerTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-acct-species")
    }

    private func storedSpec(username: String) async throws -> AvatarSpec {
        let user = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == username).first())
        return try #require(user.avatarSpecJSON.flatMap(AvatarStore.decode))
    }

    private func postChoices(_ fields: [String: String], cookie: String) async throws -> String? {
        let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var body = fields
        body["_csrf"] = token
        var location: String?
        try await app.asyncTest(
            .POST, "/account/avatar",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: newCookie)
                try req.content.encode(body, as: .urlEncodedForm)
            },
            afterResponse: { res in
                #expect(res.status == .seeOther)
                location = res.headers.first(name: .location)
            })
        return location
    }

    /// The colourway radio for `value`, from its name to its closing bracket,
    /// so a test can read its attributes and whether it is checked.
    private func capRadio(in html: String, value: String) throws -> Substring {
        let start = try #require(html.range(of: "name=\"cap\" value=\"\(value)\""), "no radio for \(value)")
        let end = try #require(html[start.lowerBound...].firstIndex(of: ">"))
        return html[start.lowerBound..<end]
    }

    /// Stores `cap` as the user's colourway, which fixes the species.
    private func setColourway(_ cap: AvatarCap, username: String) async throws {
        let user = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == username).first())
        var spec = try #require(user.avatarSpecJSON.flatMap(AvatarStore.decode))
        spec.cap = cap
        user.avatarSpecJSON = AvatarStore.encode(spec)
        try await user.save(on: app.db)
    }

    private func accountPage(cookie: String) async throws -> String {
        var html = ""
        try await app.asyncTest(
            .GET, "/account",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                #expect(res.status == .ok)
                html = res.body.string
            })
        return html
    }

    @Test func savingAnOwnSpeciesColourwayKeepsTheRestOfTheBird() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "species_save", password: "pw", role: "student", on: app)
            _ = try await accountPage(cookie: cookie)
            try await setColourway(.teal, username: "species_save")
            let before = try await storedSpec(username: "species_save")

            let location = try await postChoices(["cap": "plum"], cookie: cookie)
            #expect(location == "/account?avatar=saved#chickadee")

            let after = try await storedSpec(username: "species_save")
            var expected = before
            expected.cap = .plum
            #expect(after == expected, "a slot other than the colourway changed")

            let html = try await accountPage(cookie: cookie)
            #expect(try capRadio(in: html, value: "plum").hasSuffix(" checked"))
            #expect(try !capRadio(in: html, value: "teal").hasSuffix(" checked"))
            #expect(html.contains("--av-body: var(--avatar-plum-body)"))
        }
    }

    @Test func anotherSpeciesColourwayIsRefusedAndTheBirdIsKept() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "species_other", password: "pw", role: "student", on: app)
            _ = try await accountPage(cookie: cookie)
            try await setColourway(.teal, username: "species_other")
            let before = try await storedSpec(username: "species_other")
            let location = try await postChoices(["cap": "copper", "backdrop": "sky"], cookie: cookie)
            #expect(location == "/account?avatar=invalid#chickadee")
            #expect(try await storedSpec(username: "species_other") == before)
        }
    }

    @Test func anUnknownColourwayIsRefused() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "species_bad", password: "pw", role: "student", on: app)
            _ = try await accountPage(cookie: cookie)
            let before = try await storedSpec(username: "species_bad")
            let location = try await postChoices(["cap": "chartreuse"], cookie: cookie)
            #expect(location == "/account?avatar=invalid#chickadee")
            #expect(try await storedSpec(username: "species_bad") == before)
        }
    }

    @Test func thePageOffersExactlyTheOwnSpeciesColourways() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "species_page", password: "pw", role: "student", on: app)
            _ = try await accountPage(cookie: cookie)
            try await setColourway(.scarlet, username: "species_page")
            let html = try await accountPage(cookie: cookie)

            // One radio per cardinal colourway, each carrying the six tone
            // tokens and the three layers the live preview sets.
            #expect(html.components(separatedBy: "name=\"cap\"").count - 1 == AvatarSpecies.cardinal.colourways.count)
            for cap in AvatarSpecies.cardinal.colourways {
                #expect(html.contains(#"name="cap" value="\#(cap.rawValue)""#), "no radio for \(cap)")
                for tone in ["cap", "wing", "body", "bib", "beak", "mark"] {
                    #expect(
                        html.contains(#"data-av-\#(tone)="--avatar-\#(cap.rawValue)-\#(tone)""#),
                        "\(cap) radio lacks its \(tone) token")
                }
                #expect(
                    try capRadio(in: html, value: cap.rawValue).contains("data-av-plumage=\"#av-plumage-cardinal\""))
            }
            for cap in AvatarCap.allCases where AvatarSpecies.of(cap) != .cardinal {
                #expect(!html.contains(#"name="cap" value="\#(cap.rawValue)""#), "\(cap) is offered")
            }
            // No Species group: the colour note names the species instead.
            #expect(!html.contains("<legend>Species</legend>"))
            #expect(html.contains("<legend>Colour</legend>"))
            #expect(html.contains("Three cardinal colourways, plus your backdrop."))
            #expect(html.contains("<strong>Cardinal</strong>"))
            // The chosen colourway is the one checked radio, and its tuft layer
            // is the cardinal crest in the shape the student's own tuft slot
            // picks (a hat would hide it; a fresh test user wears none).
            let scarlet = try capRadio(in: html, value: "scarlet")
            #expect(scarlet.hasSuffix(" checked"))
            #expect(scarlet.contains("data-av-tuft=\"#av-crest-cardinal-"))
            #expect(html.contains("swatch-bird"))
            #expect(html.contains("Scarlet</span>"))
            #expect(!html.contains("var()"), "a sample token resolved to empty")
        }
    }

    /// A chickadee has the widest Colour group: its eight colourways.
    @Test func aChickadeeIsOfferedItsEightColourways() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "species_eight", password: "pw", role: "student", on: app)
            _ = try await accountPage(cookie: cookie)
            try await setColourway(.ink, username: "species_eight")
            let html = try await accountPage(cookie: cookie)
            #expect(html.components(separatedBy: "name=\"cap\"").count - 1 == 8)
            #expect(html.contains("Eight chickadee colourways, plus your backdrop."))
        }
    }

    /// Staff keep their ring note and may choose a colourway of their own
    /// species, like a student.
    @Test func staffMayChooseAnOwnSpeciesColourway() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "species_staff", password: "pw", role: "instructor", on: app)
            let course = try await makeTestCourse(on: app, code: "SPC101")
            let user = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "species_staff").first())
            try await APICourseEnrollment(
                userID: try user.requireID(), courseID: try course.requireID(), role: .instructor
            ).save(on: app.db)
            _ = try await accountPage(cookie: cookie)
            try await setColourway(.azure, username: "species_staff")

            let html = try await accountPage(cookie: cookie)
            #expect(html.contains("<legend>Colour</legend>"))
            #expect(html.contains("Course staff wear the staff ring in every course"))

            let location = try await postChoices(["cap": "cobalt"], cookie: cookie)
            #expect(location == "/account?avatar=saved#chickadee")
            #expect(try await storedSpec(username: "species_staff").cap == .cobalt)
            let refused = try await postChoices(["cap": "copper"], cookie: cookie)
            #expect(refused == "/account?avatar=invalid#chickadee")
            #expect(try await storedSpec(username: "species_staff").cap == .cobalt)
        }
    }
}
