// Tests/APITests/Gamification/WardrobeUnlockRoutesTests.swift
//
// Wardrobe unlocks on the account page (#2592): a student's own graded work
// earns an item, the account page grants it and offers it as a choice, the
// save route accepts it, an unlock is kept after a regrade, and the export
// carries it.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct WardrobeUnlockRoutesTests {

    /// Gives the logged-in student one graded submission on a new assignment.
    private func gradeSubmission(
        id: String, setupID: String, attempt: Int = 1, statuses: [TestStatus], on app: Application
    ) async throws {
        let student = try await wrStudentUser(on: app)
        try await wrEnrollUser(student, on: app)
        if try await APITestSetup.find(setupID, on: app.db) == nil {
            try await wrInsertSetup(id: setupID, on: app)
            try await wrInsertAssignment(testSetupID: setupID, title: "Lab \(setupID)", isOpen: true, on: app)
        }
        try await wrInsertSubmission(
            id: id, testSetupID: setupID, userID: student.requireID(), attemptNumber: attempt, on: app)
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

    private func save(_ fields: [String: String], cookie: String, on app: Application) async throws -> String? {
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

    @Test func withNoGradedWorkNothingIsEarnedOrShown() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let html = try await getHTML("/account", cookie: cookie, on: app)
            #expect(try await storedUnlocks(on: app).isEmpty)
            #expect(!html.contains("· earned"))
            #expect(!html.contains("How you earned these"))
            #expect(!html.contains(#"name="expression" value="chirp""#))
            #expect(
                try await save(["expression": "chirp"], cookie: cookie, on: app) == "/account?avatar=invalid#chickadee")
        }
    }

    @Test func aFirstGradedSubmissionOpensTheChirpFace() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await gradeSubmission(id: "wu_s1", setupID: "wu_a", attempt: 2, statuses: [.fail], on: app)
            let html = try await getHTML("/account", cookie: cookie, on: app)

            #expect(try await storedUnlocks(on: app) == ["expression.chirp"])
            #expect(html.contains(#"name="expression" value="chirp""#))
            #expect(!html.contains("Chirp · earned"))
            #expect(html.contains("Chirp: earned by a first graded submission"))
            #expect(!html.contains(#"name="expression" value="sly""#))

            #expect(
                try await save(["expression": "chirp"], cookie: cookie, on: app) == "/account?avatar=saved#chickadee")
            let student = try await wrStudentUser(on: app)
            #expect(student.avatarSpecJSON.flatMap(AvatarStore.decode)?.expression == .chirp)
        }
    }

    @Test func fullMarksOnAFirstTryOpensTheSlyFace() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await gradeSubmission(id: "wu_s2", setupID: "wu_b", attempt: 1, statuses: [.pass, .pass], on: app)
            let html = try await getHTML("/account", cookie: cookie, on: app)
            #expect(try await storedUnlocks(on: app) == ["expression.chirp", "expression.sly"])
            #expect(html.contains(#"name="expression" value="sly""#))
        }
    }

    @Test func fullMarksOnThreeAssignmentsOpensTheTwoToneRing() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            for (index, setup) in ["wu_c1", "wu_c2", "wu_c3"].enumerated() {
                try await gradeSubmission(
                    id: "wu_c\(index)", setupID: setup, attempt: 2, statuses: [.pass], on: app)
            }
            let html = try await getHTML("/account", cookie: cookie, on: app)
            #expect(try await storedUnlocks(on: app).contains("border.twotone"))
            #expect(html.contains(#"name="border" value="twotone""#))
            #expect(try await save(["border": "twotone"], cookie: cookie, on: app) == "/account?avatar=saved#chickadee")
        }
    }

    /// An unlock is kept when the work that earned it is regraded away.
    @Test func anUnlockIsKeptAfterARegrade() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await gradeSubmission(id: "wu_s4", setupID: "wu_d", attempt: 1, statuses: [.pass], on: app)
            _ = try await getHTML("/account", cookie: cookie, on: app)
            #expect(try await storedUnlocks(on: app).contains("expression.sly"))

            try await APIResult.query(on: app.db).filter(\.$submissionID == "wu_s4").delete()
            let html = try await getHTML("/account", cookie: cookie, on: app)
            #expect(try await storedUnlocks(on: app).contains("expression.sly"))
            #expect(html.contains(#"name="expression" value="sly""#))
        }
    }

    /// Validation and other staff work is not a student's own graded work.
    @Test func onlyStudentSubmissionsCount() async throws {
        try await withWebRoutesApp { app in
            _ = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrEnrollUser(student, on: app)
            try await wrInsertSetup(id: "wu_e", on: app)
            let validation = APISubmission(
                id: "wu_v1", testSetupID: "wu_e", zipPath: app.submissionsDirectory + "wu_v1.py",
                attemptNumber: 1, status: "complete", filename: nil, userID: try student.requireID(),
                kind: APISubmission.Kind.validation)
            try await validation.save(on: app.db)
            try await wrInsertResult(
                submissionID: "wu_v1", outcomes: [wrMakeOutcome(name: "t.sh", status: .pass)], on: app)
            let progress = try await WardrobeUnlockStore.progress(for: student.requireID(), on: app.db)
            #expect(
                progress
                    == WardrobeProgress(
                        hasGradedSubmission: false, hasFirstTryFullMarks: false, fullMarksAssignments: 0))
        }
    }

    @Test func theExportCarriesTheUnlocks() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await gradeSubmission(id: "wu_s5", setupID: "wu_f", attempt: 1, statuses: [.fail], on: app)
            _ = try await getHTML("/account", cookie: cookie, on: app)
            let student = try await wrStudentUser(on: app)
            let content = try await gatherDataExportContent(for: student, on: app.db)
            #expect(content.profile.wardrobeUnlocks?.map(\.item) == ["expression.chirp"])
            #expect(dataExportReadme(username: "student1", generatedAt: Date()).contains("wardrobe items"))
        }
    }
}
