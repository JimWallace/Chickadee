// Tests/APITests/AccountSpeciesPickerTests.swift
//
// The Species group of the account page's bird picker
// (docs/avatar-species.md, A2): POST /account/avatar with `cap` changes the
// colourway, and with it the species, and the page offers every colourway
// grouped by species with the data the live preview needs.

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

    @Test func savingAColourwayChangesTheSpeciesAndKeepsTheRestOfTheBird() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "species_save", password: "pw", role: "student", on: app)
            _ = try await accountPage(cookie: cookie)
            let before = try await storedSpec(username: "species_save")

            let location = try await postChoices(["cap": "copper"], cookie: cookie)
            #expect(location == "/account?avatar=saved#chickadee")

            let after = try await storedSpec(username: "species_save")
            #expect(after.species == .robin)
            var expected = before
            expected.cap = .copper
            #expect(after == expected, "a slot other than the colourway changed")

            // The page now draws the robin's plumage, and the robin radio is
            // the checked one.
            let html = try await accountPage(cookie: cookie)
            #expect(html.contains("<use href=\"#av-plumage-robin\" />"))
            #expect(try capRadio(in: html, value: "copper").hasSuffix(" checked"))
            #expect(try !capRadio(in: html, value: "teal").hasSuffix(" checked"))
            #expect(html.contains("--av-body: var(--avatar-copper-body)"))
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

    @Test func thePageOffersEveryColourwayGroupedBySpecies() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "species_page", password: "pw", role: "student", on: app)
            _ = try await postChoices(["cap": "scarlet"], cookie: cookie)
            let html = try await accountPage(cookie: cookie)

            // One radio per colourway, each carrying the six tone tokens and
            // the two layers the live preview sets.
            for cap in AvatarCap.allCases {
                let species = AvatarSpecies.of(cap)
                #expect(html.contains(#"name="cap" value="\#(cap.rawValue)""#), "no radio for \(cap)")
                for tone in ["cap", "wing", "body", "bib", "beak", "mark"] {
                    #expect(
                        html.contains(#"data-av-\#(tone)="--avatar-\#(cap.rawValue)-\#(tone)""#),
                        "\(cap) radio lacks its \(tone) token")
                }
                #expect(
                    html.contains("data-av-plumage=\"#av-plumage-\(species.rawValue)\""),
                    "\(cap) radio lacks its plumage")
            }
            // Grouped under one legend per species, in species order.
            var lastLegend = html.startIndex
            for species in AvatarSpecies.allCases {
                let legend = try #require(
                    html.range(of: "<legend>\(species.displayName)</legend>", range: lastLegend..<html.endIndex),
                    "no group for \(species)")
                lastLegend = legend.upperBound
            }
            // The chosen colourway is the one checked radio, and its tuft layer
            // is the crest or tuft the student's own bird would wear.
            let scarlet = try capRadio(in: html, value: "scarlet")
            #expect(scarlet.hasSuffix(" checked"))
            #expect(
                scarlet.contains("data-av-tuft=\"#av-crest-cardinal\"") || scarlet.contains("data-av-tuft=\"#av-tuft-"))
            let checkedCaps = html.components(separatedBy: "name=\"cap\"").dropFirst()
                .filter { $0.prefix { $0 != ">" }.hasSuffix(" checked") }
            #expect(checkedCaps.count == 1)
            #expect(html.components(separatedBy: "name=\"cap\"").count - 1 == AvatarCap.allCases.count)
            // The sample is the student's own bird in that colourway.
            #expect(html.contains("swatch-bird"))
            #expect(html.contains("Scarlet</span>"))
            #expect(!html.contains("var()"), "a sample token resolved to empty")
        }
    }

    /// Staff keep their ring note but may choose a species.
    @Test func staffSeeTheSpeciesGroupAndMayChoose() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "species_staff", password: "pw", role: "instructor", on: app)
            let course = try await makeTestCourse(on: app, code: "SPC101")
            let user = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "species_staff").first())
            try await APICourseEnrollment(
                userID: try user.requireID(), courseID: try course.requireID(), role: .instructor
            ).save(on: app.db)

            let html = try await accountPage(cookie: cookie)
            #expect(html.contains("<legend>Species</legend>"))
            #expect(html.contains("Course staff wear the staff ring."))

            let location = try await postChoices(["cap": "azure"], cookie: cookie)
            #expect(location == "/account?avatar=saved#chickadee")
            #expect(try await storedSpec(username: "species_staff").species == .bluejay)
        }
    }
}
