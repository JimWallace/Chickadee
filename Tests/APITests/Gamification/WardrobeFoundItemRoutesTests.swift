// Tests/APITests/Gamification/WardrobeFoundItemRoutesTests.swift
//
// The Quantum Cats ring over the web surface (docs/student-wardrobe.md,
// "Found items"):
//
//   - POST /account/wardrobe/found grants the ring once, and says so once
//   - the account page then offers the ring, and a save can wear it
//   - an earned item and an unknown value are refused, and store nothing
//   - a post without the CSRF token is refused
//   - a student's signed-in page carries the script and the hidden Earned
//     toast for the ring; course staff, who wear the staff ring, get no toast;
//     the account page, which is the ring picker, gets the script only

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct WardrobeFoundItemRoutesTests {

    private func storedUnlocks(on app: Application) async throws -> Set<String> {
        let student = try await wrStudentUser(on: app)
        return Set(
            try await APIWardrobeUnlock.query(on: app.db).filter(\.$userID == student.requireID()).all().map(\.item))
    }

    /// Posts `item` as the Konami script does: JSON, with the CSRF header.
    /// Returns the status and the body.
    private func postFound(
        _ item: String, csrf: String?, cookie: String, on app: Application
    ) async throws -> (HTTPStatus, String) {
        var status: HTTPStatus = .internalServerError
        var body = ""
        try await app.asyncTest(
            .POST, "/account/wardrobe/found",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                if let csrf { req.headers.add(name: "x-csrf-token", value: csrf) }
                req.headers.add(name: .accept, value: "application/json")
                try req.content.encode(["item": item], as: .json)
            },
            afterResponse: { res in
                status = res.status
                body = res.body.string
            })
        return (status, body)
    }

    @Test func theRingIsGrantedOnceAndOfferedOnTheAccountPage() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let before = try await getHTML("/account", cookie: cookie, on: app)
            #expect(!before.contains(#"name="border" value="quantumcats""#))

            let (csrf, session) = try await csrfFields(for: "/account", cookie: cookie, on: app)
            let first = try await postFound("border.quantumcats", csrf: csrf, cookie: session, on: app)
            #expect(first.0 == .ok)
            #expect(first.1.contains(#""granted":true"#))
            #expect(try await storedUnlocks(on: app) == ["border.quantumcats"])

            // A second find stores nothing more, and says it is not new.
            let second = try await postFound("border.quantumcats", csrf: csrf, cookie: session, on: app)
            #expect(second.0 == .ok)
            #expect(second.1.contains(#""granted":false"#))
            #expect(try await APIWardrobeUnlock.query(on: app.db).count() == 1)

            let after = try await getHTML("/account", cookie: session, on: app)
            #expect(after.contains(#"name="border" value="quantumcats""#))
        }
    }

    @Test func anEarnedItemOrAnUnknownValueIsRefused() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let (csrf, session) = try await csrfFields(for: "/account", cookie: cookie, on: app)
            for item in ["border.ouroboros", "expression.chirp", "border.nothing", ""] {
                let (status, _) = try await postFound(item, csrf: csrf, cookie: session, on: app)
                #expect(status == .badRequest, "\(item): \(status)")
            }
            #expect(try await storedUnlocks(on: app).isEmpty)
        }
    }

    @Test func aPostWithoutTheCSRFTokenIsRefused() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let (status, _) = try await postFound("border.quantumcats", csrf: nil, cookie: cookie, on: app)
            #expect(status == .forbidden)
            #expect(try await storedUnlocks(on: app).isEmpty)
        }
    }

    @Test func aStudentPageCarriesTheScriptAndTheHiddenToast() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            // The account page draws the bird, so it is stored from here on.
            _ = try await getHTML("/account", cookie: cookie, on: app)
            let html = try await getHTML("/", cookie: cookie, on: app)
            #expect(html.contains("/quantum-cats-egg.js"))
            // The toast's opening tag carries the id and starts hidden.
            let start = try #require(html.range(of: #"id="quantum-cats-found""#))
            let tagStart = try #require(html[..<start.lowerBound].lastIndex(of: "<"))
            let tagEnd = try #require(html[start.upperBound...].firstIndex(of: ">"))
            let tag = html[tagStart...tagEnd]
            #expect(tag.contains(" hidden"))
            #expect(tag.contains("nb-graded-earned"))
            #expect(tag.contains("is-ring"))
            #expect(html.contains("Found by entering the Konami code."))
            #expect(html.contains(#"value="quantumcats""#))
            #expect(html.contains("#av-ring-quantumcats"))
        }
    }

    @Test func courseStaffGetNoToast() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            _ = try await getHTML("/account", cookie: cookie, on: app)
            let html = try await getHTML("/", cookie: cookie, on: app)
            #expect(html.contains("/quantum-cats-egg.js"))
            #expect(!html.contains("quantum-cats-found"))
        }
    }

    @Test func theAccountPageHasTheScriptButNoToast() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let html = try await getHTML("/account", cookie: cookie, on: app)
            #expect(html.contains("/quantum-cats-egg.js"))
            #expect(!html.contains("quantum-cats-found"))
        }
    }

    @Test func theSignInPageHasNeither() async throws {
        try await withWebRoutesApp { app in
            let html = try await getHTML("/login", cookie: "", on: app)
            #expect(!html.contains("/quantum-cats-egg.js"))
            #expect(!html.contains("quantum-cats-found"))
        }
    }
}
