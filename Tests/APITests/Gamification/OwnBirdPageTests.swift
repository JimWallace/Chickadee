// Tests/APITests/Gamification/OwnBirdPageTests.swift
//
// The user's own bird outside the account page: in the nav's account menu on
// every signed-in page, and on the student's own result page, where it chirps
// and hops on a clean pass (Core/AvatarReaction.swift).

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized) struct OwnBirdPageTests {

    /// The account-menu toggle, from its class to the end of the button.
    private func accountMenuToggle(in html: String) throws -> Substring {
        let start = try #require(html.range(of: "nav-username"), "no account menu")
        let end = try #require(html[start.upperBound...].range(of: "</button>"), "account menu not closed")
        return html[start.lowerBound..<end.lowerBound]
    }

    // MARK: - The nav

    @Test func navShowsTheSignedInUsersBird() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrEnrollUser(student, on: app)
            let html = try await getHTML("/", cookie: cookie, on: app)

            let toggle = try accountMenuToggle(in: html)
            #expect(toggle.contains("avatar avatar-sm"))
            #expect(toggle.contains("aria-hidden=\"true\""), "the name beside the bird says whose it is")
            // The first signed-in page draws and stores the bird.
            let stored = try #require(try await APIUser.find(student.requireID(), on: app.db))
            #expect(stored.avatarSpecJSON != nil)
        }
    }

    @Test func signedInPageInlinesTheAvatarSpriteOnce() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let html = try await getHTML("/", cookie: cookie, on: app)
            #expect(html.components(separatedBy: "id=\"av-backdrop\"").count == 2)
        }
    }

    @Test func accountPageInlinesTheAvatarSpriteOnce() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let html = try await getHTML("/account", cookie: cookie, on: app)
            #expect(html.components(separatedBy: "id=\"av-backdrop\"").count == 2)
        }
    }

    @Test func loginPageHasNoBirdAndNoAvatarSprite() async throws {
        try await withWebRoutesApp { app in
            try await app.asyncTest(.GET, "/login") { res in
                #expect(res.status == .ok)
                #expect(!res.body.string.contains("id=\"av-backdrop\""))
                #expect(!res.body.string.contains("avatar avatar-sm"))
            }
        }
    }

    // MARK: - The result page

    private func seedResult(
        app: Application, setupID: String, subID: String, statuses: [TestStatus]
    ) async throws {
        let student = try await wrStudentUser(on: app)
        try await wrEnrollUser(student, on: app)
        try await wrInsertSetup(id: setupID, on: app)
        try await wrInsertAssignment(testSetupID: setupID, title: "Bird Lab", isOpen: true, on: app)
        try await wrInsertSubmission(
            id: subID, testSetupID: setupID, userID: student.requireID(), on: app)
        try await wrInsertResult(
            submissionID: subID,
            outcomes: statuses.enumerated().map { index, status in
                wrMakeOutcome(name: "test\(index).sh", tier: .pub, status: status)
            },
            on: app)
    }

    @Test func ownCleanPassShowsTheBirdCheering() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await seedResult(app: app, setupID: "setup_bird1", subID: "sub_bird1", statuses: [.pass, .pass])
            let html = try await getHTML("/submissions/sub_bird1", cookie: cookie, on: app)
            #expect(html.contains("submission-bird submission-bird-cheer"))
            #expect(html.contains("#av-expression-chirp"))
        }
    }

    @Test func ownPartialResultShowsTheBirdAsItIs() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await seedResult(app: app, setupID: "setup_bird2", subID: "sub_bird2", statuses: [.pass, .fail])
            let html = try await getHTML("/submissions/sub_bird2", cookie: cookie, on: app)
            #expect(html.contains("class=\"submission-bird\""))
            #expect(!html.contains("submission-bird-cheer"))

            let student = try await wrStudentUser(on: app)
            let spec = try #require(student.avatarSpecJSON.flatMap(AvatarStore.decode))
            #expect(html.contains("#av-expression-\(spec.expression.rawValue)"))
        }
    }

    @Test func cheerDoesNotChangeTheStoredBird() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await seedResult(app: app, setupID: "setup_bird3", subID: "sub_bird3", statuses: [.pass])
            let before = try await wrStudentUser(on: app)
            let spec = AvatarSpec.drawn(fromSeed: 3)
            before.avatarSpecJSON = AvatarStore.encode(spec)
            try await before.save(on: app.db)

            _ = try await getHTML("/submissions/sub_bird3", cookie: cookie, on: app)

            let after = try await wrStudentUser(on: app)
            #expect(after.avatarSpecJSON.flatMap(AvatarStore.decode) == spec)
        }
    }

    @Test func staffReadingAStudentsResultSeeTheStudentsBirdAsStored() async throws {
        try await withWebRoutesApp { app in
            _ = try await wrLoginAsStudent(on: app)
            try await seedResult(app: app, setupID: "setup_bird4", subID: "sub_bird4", statuses: [.pass])
            let staffCookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)

            let html = try await getHTML("/submissions/sub_bird4", cookie: staffCookie, on: app)
            #expect(html.contains("submission-score-row"))
            // The student's bird, with no reaction and no pointer motion.
            #expect(html.contains("class=\"submission-bird submission-bird-other\""))
            #expect(!html.contains("submission-bird-cheer"))
            let student = try await wrStudentUser(on: app)
            let spec = try #require(student.avatarSpecJSON.flatMap(AvatarStore.decode))
            #expect(html.contains("#av-expression-\(spec.expression.rawValue)"))
        }
    }
}
