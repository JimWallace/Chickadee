// Tests/APITests/AvatarStaffRingRoutesTests.swift
//
// The staff ring and the locked rings on real pages
// (docs/student-wardrobe.md, "Rings" and "The staff ring"): course staff wear
// the staff ring and cannot choose another, a student can choose a starter
// ring, and an earned or special ring is shown locked and refused.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct AvatarStaffRingRoutesTests {

    private func page(_ path: String, cookie: String, on app: Application) async throws -> String {
        var html = ""
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                #expect(res.status == .ok)
                html = res.body.string
            })
        return html
    }

    private func enroll(
        _ username: String, role: CourseRole = .student, on app: Application
    ) async throws -> APIUser {
        let user = try await arInsertStudent(username: username, displayName: username, on: app)
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: role)
            .save(on: app.db)
        return user
    }

    private func postChoices(
        _ fields: [String: String], cookie: String, on app: Application
    ) async throws -> String? {
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
            afterResponse: { res in location = res.headers.first(name: .location) })
        return location
    }

    private func storedSpec(_ user: APIUser, on app: Application) async throws -> AvatarSpec {
        let json = try #require(try await APIUser.find(user.requireID(), on: app.db)?.avatarSpecJSON)
        return try #require(AvatarStore.decode(json))
    }

    // MARK: - Staff

    @Test func theRosterDrawsTheStaffRingForStaffOnly() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            _ = try await enroll("ring_ta", role: .ta, on: app)
            _ = try await enroll("ring_pupil", on: app)

            let html = try await page("/instructor/students", cookie: cookie, on: app)
            let staffTable = try #require(html.range(of: "id=\"course-staff-table\""))
            let studentTable = try #require(html.range(of: "id=\"enrolled-students-table\""))
            let staffPart = html[staffTable.lowerBound..<studentTable.lowerBound]
            let studentPart = html[studentTable.lowerBound...]
            #expect(staffPart.contains("<use href=\"#av-ring-staff\" data-av-ring/>"))
            #expect(!studentPart.contains("#av-ring-staff"))
            #expect(studentPart.contains("<use href=\"#av-ring-none\" data-av-ring/>"))
        }
    }

    @Test func staffSeeTheStaffRingAndNoRingChoices() async throws {
        try await withAssignmentRoutesApp { app in
            let ta = try await enroll("ring_ta_acct", role: .ta, on: app)
            let cookie = try await loginUser(
                username: ta.username, password: "testpassword", role: "user", on: app)

            let html = try await page("/account", cookie: cookie, on: app)
            #expect(html.contains("<use href=\"#av-ring-staff\" data-av-ring/>"))
            #expect(html.contains("Course staff wear the staff ring."))
            #expect(!html.contains("name=\"border\""))
            #expect(!html.contains("Locked rings will be earned"))
            // The backdrop stays theirs to choose.
            #expect(html.contains("name=\"backdrop\""))
        }
    }

    @Test func staffCannotPostARingButCanPostABackdrop() async throws {
        try await withAssignmentRoutesApp { app in
            let ta = try await enroll("ring_ta_post", role: .instructor, on: app)
            let cookie = try await loginUser(
                username: ta.username, password: "testpassword", role: "user", on: app)
            _ = try await page("/account", cookie: cookie, on: app)
            let before = try await storedSpec(ta, on: app)

            let refused = try await postChoices(["border": "ember"], cookie: cookie, on: app)
            #expect(refused == "/account?avatar=invalid#chickadee")
            #expect(try await storedSpec(ta, on: app) == before)

            let saved = try await postChoices(["backdrop": "lilac"], cookie: cookie, on: app)
            #expect(saved == "/account?avatar=saved#chickadee")
            #expect(try await storedSpec(ta, on: app).backdrop == .lilac)
        }
    }

    // MARK: - Starter and locked rings

    @Test func aStudentCanChooseTheRainbowRing() async throws {
        try await withAssignmentRoutesApp { app in
            let pupil = try await enroll("ring_rainbow", on: app)
            let cookie = try await loginUser(
                username: pupil.username, password: "testpassword", role: "user", on: app)
            _ = try await page("/account", cookie: cookie, on: app)

            let saved = try await postChoices(["border": "rainbow"], cookie: cookie, on: app)
            #expect(saved == "/account?avatar=saved#chickadee")
            #expect(try await storedSpec(pupil, on: app).border == .rainbow)

            let html = try await page("/account", cookie: cookie, on: app)
            #expect(html.contains("<use href=\"#av-ring-rainbow\" data-av-ring/>"))
        }
    }

    @Test func lockedRingsAreShownDisabledAndRefused() async throws {
        try await withAssignmentRoutesApp { app in
            let pupil = try await enroll("ring_locked", on: app)
            let cookie = try await loginUser(
                username: pupil.username, password: "testpassword", role: "user", on: app)
            let html = try await page("/account", cookie: cookie, on: app)
            for value in ["spectrum", "twotone", "stitched"] {
                #expect(
                    html.contains(
                        ##"data-av-ring="#av-ring-\##(value)" name="border" value="\##(value)" data-av-token="--avatar-border-none" disabled>"##
                    ),
                    "\(value) is not shown disabled")
            }
            #expect(html.contains("Spectrum (locked)"))
            #expect(html.contains("Two-tone (locked)"))
            #expect(html.contains("Stitched (locked)"))
            #expect(html.contains("Locked rings will be earned through course achievements."))
            #expect(
                !html.contains(
                    ##"value="rainbow" data-av-token="--avatar-border-none" disabled"##
                ))

            let before = try await storedSpec(pupil, on: app)
            let refused = try await postChoices(["border": "spectrum"], cookie: cookie, on: app)
            #expect(refused == "/account?avatar=invalid#chickadee")
            #expect(try await storedSpec(pupil, on: app) == before)
        }
    }
}
