// Tests/APITests/AccountExpressionPickerTests.swift
//
// The Face group of the account page's "Your bird" card (#2588): a student
// chooses the bird's expression, and the species and colourway come with the
// bird. POST /account/avatar with `expression` changes the face only, refuses
// an unlockable face, ignores a colourway, and the page offers the starter faces
// with the data the live preview needs, and the unlockable ones as locked.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AccountExpressionPickerTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-acct-face")
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

    /// The face radio for `value`, from its name to its closing bracket, so a
    /// test can read its attributes and whether it is checked.
    private func faceRadio(in html: String, value: String) throws -> Substring {
        let start = try #require(
            html.range(of: "name=\"expression\" value=\"\(value)\""), "no radio for \(value)")
        let end = try #require(html[start.lowerBound...].firstIndex(of: ">"))
        return html[start.lowerBound..<end]
    }

    /// Stores `expression` as the user's face.
    private func setFace(_ expression: AvatarExpression, username: String) async throws {
        let user = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == username).first())
        var spec = try #require(user.avatarSpecJSON.flatMap(AvatarStore.decode))
        spec.expression = expression
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

    @Test func savingAStarterFaceKeepsTheRestOfTheBird() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "face_save", password: "pw", role: "student", on: app)
            _ = try await accountPage(cookie: cookie)
            try await setFace(.wink, username: "face_save")
            let before = try await storedSpec(username: "face_save")

            let location = try await postChoices(["expression": "sleepy"], cookie: cookie)
            #expect(location == "/account?avatar=saved#chickadee")

            let after = try await storedSpec(username: "face_save")
            var expected = before
            expected.expression = .sleepy
            #expect(after == expected, "a slot other than the face changed")

            let html = try await accountPage(cookie: cookie)
            #expect(try faceRadio(in: html, value: "sleepy").hasSuffix(" checked"))
            #expect(try !faceRadio(in: html, value: "wink").hasSuffix(" checked"))
        }
    }

    @Test func anUnlockableFaceIsRefusedAndTheBirdIsKept() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "face_locked", password: "pw", role: "student", on: app)
            _ = try await accountPage(cookie: cookie)
            try await setFace(.wink, username: "face_locked")
            let before = try await storedSpec(username: "face_locked")
            let location = try await postChoices(["expression": "chirp", "backdrop": "sky"], cookie: cookie)
            #expect(location == "/account?avatar=invalid#chickadee")
            #expect(try await storedSpec(username: "face_locked") == before)
        }
    }

    /// The form has no colourway field: a `cap` in the request is ignored,
    /// so the colourway stays as drawn while the other choices save.
    @Test func aColourwayInTheRequestChangesNothing() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "face_cap", password: "pw", role: "student", on: app)
            _ = try await accountPage(cookie: cookie)
            let before = try await storedSpec(username: "face_cap")
            let other = AvatarCap.allCases.first { $0 != before.cap } ?? .plum
            let location = try await postChoices(["cap": other.rawValue, "backdrop": "sky"], cookie: cookie)
            #expect(location == "/account?avatar=saved#chickadee")
            let after = try await storedSpec(username: "face_cap")
            #expect(after.cap == before.cap)
            #expect(after.backdrop == .sky)
        }
    }

    @Test func anUnknownFaceIsRefused() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "face_bad", password: "pw", role: "student", on: app)
            _ = try await accountPage(cookie: cookie)
            let before = try await storedSpec(username: "face_bad")
            let location = try await postChoices(["expression": "grumpy"], cookie: cookie)
            #expect(location == "/account?avatar=invalid#chickadee")
            #expect(try await storedSpec(username: "face_bad") == before)
        }
    }

    @Test func thePageOffersTheStarterFacesAndShowsTheOthersLocked() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "face_page", password: "pw", role: "student", on: app)
            _ = try await accountPage(cookie: cookie)
            try await setFace(.curious, username: "face_page")
            let html = try await accountPage(cookie: cookie)

            // One radio per starter face, each carrying the symbol the live
            // preview points the face layer at.
            #expect(
                html.components(separatedBy: "name=\"expression\"").count - 1
                    == AvatarExpression.starterCases.count)
            for face in AvatarExpression.starterCases {
                #expect(
                    try faceRadio(in: html, value: face.rawValue)
                        .contains("data-av-expression=\"#av-expression-\(face.rawValue)\""))
            }
            // The unlockable faces are listed, locked, and are not inputs.
            for face in [AvatarExpression.chirp, .sly, .dreamy] {
                #expect(!html.contains(#"name="expression" value="\#(face.rawValue)""#), "\(face) is offered")
                #expect(html.contains("\(face.displayName) · earned"), "\(face) is not listed")
            }
            // No colourway choice: the species and colours come with the bird.
            #expect(!html.contains("name=\"cap\""))
            #expect(!html.contains("<legend>Colour</legend>"))
            #expect(html.contains("<legend>Face</legend>"))
            #expect(html.contains("<legend>Backdrop</legend>"))
            #expect(try faceRadio(in: html, value: "curious").hasSuffix(" checked"))
            #expect(html.contains("Curious</span>"))
            #expect(!html.contains("var()"), "a sample token resolved to empty")
        }
    }

    /// A bird that already wears an unlockable face keeps it: the face is a
    /// checked radio, not a locked item, so saving the form keeps it.
    @Test func aWornUnlockableFaceIsOfferedAndKept() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "face_worn", password: "pw", role: "student", on: app)
            _ = try await accountPage(cookie: cookie)
            try await setFace(.chirp, username: "face_worn")
            let html = try await accountPage(cookie: cookie)
            #expect(try faceRadio(in: html, value: "chirp").hasSuffix(" checked"))
            #expect(!html.contains("Chirp · earned"))

            let location = try await postChoices(["expression": "chirp", "backdrop": "sky"], cookie: cookie)
            #expect(location == "/account?avatar=saved#chickadee")
            #expect(try await storedSpec(username: "face_worn").expression == .chirp)
        }
    }

    /// Staff keep their ring note and may choose their face, like a student.
    @Test func staffMayChooseTheirFace() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "face_staff", password: "pw", role: "instructor", on: app)
            let course = try await makeTestCourse(on: app, code: "FCE101")
            let user = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "face_staff").first())
            try await APICourseEnrollment(
                userID: try user.requireID(), courseID: try course.requireID(), role: .instructor
            ).save(on: app.db)
            _ = try await accountPage(cookie: cookie)

            let html = try await accountPage(cookie: cookie)
            #expect(html.contains("<legend>Face</legend>"))
            #expect(html.contains("Course staff wear the staff ring in every course"))

            let location = try await postChoices(["expression": "keen"], cookie: cookie)
            #expect(location == "/account?avatar=saved#chickadee")
            #expect(try await storedSpec(username: "face_staff").expression == .keen)
        }
    }
}
