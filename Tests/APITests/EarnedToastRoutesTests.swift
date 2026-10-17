// Tests/APITests/EarnedToastRoutesTests.swift
//
// The Earned toast on the result page (docs/result-celebration.md, J2): the
// result page grants what the student has earned and shows the first new
// item once, Wear it saves in place, and course staff are never offered a
// ring.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct EarnedToastRoutesTests {

    /// Gives the logged-in student one graded submission on a new assignment.
    private func gradeSubmission(
        id: String, setupID: String, attempt: Int = 1, status: String = "complete", statuses: [TestStatus],
        on app: Application
    ) async throws {
        let student = try await wrStudentUser(on: app)
        try await wrEnrollUser(student, on: app)
        if try await APITestSetup.find(setupID, on: app.db) == nil {
            try await wrInsertSetup(id: setupID, on: app)
            try await wrInsertAssignment(testSetupID: setupID, title: "Lab \(setupID)", isOpen: true, on: app)
        }
        try await wrInsertSubmission(
            id: id, testSetupID: setupID, userID: student.requireID(), attemptNumber: attempt, status: status,
            on: app)
        guard status == "complete" else { return }
        try await wrInsertResult(
            submissionID: id,
            outcomes: statuses.enumerated().map { index, status in
                wrMakeOutcome(name: "test\(index).sh", tier: .pub, status: status)
            },
            on: app)
    }

    private func storedUnlocks(on app: Application) async throws -> Set<String> {
        let student = try await wrStudentUser(on: app)
        return Set(
            try await APIWardrobeUnlock.query(on: app.db).filter(\.$userID == student.requireID()).all().map(\.item))
    }

    private func store(_ items: [WardrobeItem], on app: Application) async throws {
        let student = try await wrStudentUser(on: app)
        for item in items {
            try await APIWardrobeUnlock(userID: student.requireID(), item: item).save(on: app.db)
        }
    }

    /// Three full-marks assignments on later attempts: the two-tone ring.
    private func earnTwoTone(on app: Application) async throws {
        for index in 1...3 {
            try await gradeSubmission(
                id: "et_r\(index)", setupID: "et_ring\(index)", attempt: 2, statuses: [.pass], on: app)
        }
    }

    /// Posts a choice as the toast's Wear it does, asking for JSON.
    private func wearInPlace(
        _ fields: [String: String], cookie: String, on app: Application
    ) async throws -> (status: HTTPStatus, location: String?) {
        let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var body = fields
        body["_csrf"] = token
        var result: (HTTPStatus, String?) = (.internalServerError, nil)
        try await app.asyncTest(
            .POST, "/account/avatar",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: newCookie)
                req.headers.replaceOrAdd(name: .accept, value: "application/json")
                try req.content.encode(body, as: .urlEncodedForm)
            },
            afterResponse: { res in result = (res.status, res.headers.first(name: .location)) })
        return result
    }

    @Test func aFirstGradedResultShowsTheChirpFaceOnce() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await gradeSubmission(id: "et_s1", setupID: "et_a", attempt: 2, statuses: [.fail], on: app)

            let html = try await getHTML("/submissions/et_s1", cookie: cookie, on: app)
            #expect(try await storedUnlocks(on: app) == ["expression.chirp"])
            #expect(html.contains(#"id="earned-toast""#))
            #expect(html.contains("New face"))
            #expect(html.contains("Chirp"))
            #expect(html.contains("Earned by a first graded submission."))
            #expect(html.contains(#"data-announce="New face earned: Chirp.""#))
            #expect(html.contains(#"name="expression" value="chirp""#))
            #expect(html.contains(##"data-wear-face="#av-expression-chirp""##))
            #expect(html.contains("/earned-toast.js"))

            // A grant happens once, so a reload shows no toast.
            let again = try await getHTML("/submissions/et_s1", cookie: cookie, on: app)
            #expect(!again.contains("earned-toast"))
        }
    }

    @Test func anItemTheAccountPageGrantedFirstShowsNoToast() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await gradeSubmission(id: "et_s2", setupID: "et_b", statuses: [.fail], on: app)
            _ = try await getHTML("/account", cookie: cookie, on: app)

            let html = try await getHTML("/submissions/et_s2", cookie: cookie, on: app)
            #expect(!html.contains("earned-toast"))
        }
    }

    @Test func aPendingResultGrantsNothing() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await gradeSubmission(id: "et_s3", setupID: "et_c", status: "pending", statuses: [], on: app)

            let html = try await getHTML("/submissions/et_s3", cookie: cookie, on: app)
            #expect(!html.contains("earned-toast"))
            #expect(try await storedUnlocks(on: app).isEmpty)
        }
    }

    /// A new ring shows as a ring, with where it starts to draw in.
    @Test func aNewRingShowsAsARing() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await store([.chirpFace], on: app)
            try await earnTwoTone(on: app)

            let html = try await getHTML("/submissions/et_r3", cookie: cookie, on: app)
            #expect(html.contains("nb-graded nb-graded-earned is-ring"))
            #expect(html.contains("New ring"))
            #expect(html.contains("Earned when every test passed on three assignments."))
            #expect(html.contains("--earned-ring-start: 0deg"))
            #expect(html.contains(#"name="border" value="twotone""#))
            #expect(html.contains(##"data-wear-ring="#av-ring-twotone""##))
        }
    }

    @Test func courseStaffAreNotOfferedARing() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            let taCourse = APICourse(code: "TA101", name: "Teaching")
            try await taCourse.save(on: app.db)
            try await APICourseEnrollment(userID: student.requireID(), courseID: taCourse.requireID(), role: .ta)
                .save(on: app.db)
            try await store([.chirpFace], on: app)
            try await earnTwoTone(on: app)

            let html = try await getHTML("/submissions/et_r3", cookie: cookie, on: app)
            #expect(try await storedUnlocks(on: app).contains("border.twotone"))
            #expect(!html.contains("earned-toast"))
        }
    }

    @Test func wearItSavesInPlace() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await gradeSubmission(id: "et_s4", setupID: "et_d", statuses: [.fail], on: app)
            _ = try await getHTML("/submissions/et_s4", cookie: cookie, on: app)

            let saved = try await wearInPlace(["expression": "chirp"], cookie: cookie, on: app)
            #expect(saved.status == .noContent)
            #expect(saved.location == nil)
            let student = try await wrStudentUser(on: app)
            #expect(student.avatarSpecJSON.flatMap(AvatarStore.decode)?.expression == .chirp)

            let refused = try await wearInPlace(["expression": "sly"], cookie: cookie, on: app)
            #expect(refused.status == .unprocessableEntity)
        }
    }
}
