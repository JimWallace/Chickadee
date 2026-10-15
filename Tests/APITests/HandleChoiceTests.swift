// Tests/APITests/HandleChoiceTests.swift
//
// The handle names the bird (docs/student-avatars.md §3): one handle per
// student, the same in every course, shown on the account page's bird card.
// There is no per-course "Change handle" panel any more, and nothing locks a
// handle: a hatch is how a student changes their name and bird at once.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct HandleChoiceTests {

    // MARK: - Helpers

    /// The student logged in and enrolled in the default course. Returns the
    /// session cookie and the student.
    private func loggedInStudent(on app: Application) async throws -> (cookie: String, student: APIUser) {
        let cookie = try await wrLoginAsStudent(on: app)
        let student = try await wrStudentUser(on: app)
        try await wrEnrollUser(student, on: app)
        return (cookie, student)
    }

    private func storedUser(_ user: APIUser, on app: Application) async throws -> APIUser {
        try #require(try await APIUser.find(user.id, on: app.db))
    }

    // MARK: - The account page

    @Test func theBirdCardNamesTheBirdByItsHandle() async throws {
        try await withWebRoutesApp { app in
            let (cookie, student) = try await loggedInStudent(on: app)
            let html = try await getResponse("/account", cookie: cookie, on: app).body.string
            let handle = try #require(try await storedUser(student, on: app).avatarHandle)
            #expect(html.contains(#"<strong data-avatar-handle>\#(handle)</strong>"#))
            // One name, on the card: no per-course handle line, no panel.
            #expect(!html.contains("Class handle:"))
            #expect(!html.contains("Change handle"))
            #expect(!html.contains("/account/handle/"))
        }
    }

    @Test func thePerCourseHandleRouteIsGone() async throws {
        try await withWebRoutesApp { app in
            let (cookie, _) = try await loggedInStudent(on: app)
            let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
            let course = try #require(try await APICourse.query(on: app.db).first())
            try await app.asyncTest(
                .POST, "/account/handle/\(try course.requireID().uuidString)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["_csrf": token, "handle": "Quiet Cedar"], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .notFound) })
        }
    }

    /// Staff appear under their own name, so a staff-only account's bird has
    /// no handle and its card shows none.
    @Test func aStaffOnlyBirdHasNoHandle() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            let html = try await getResponse("/account", cookie: cookie, on: app).body.string
            #expect(!html.contains("data-avatar-handle"))
            #expect(try await storedUser(instructor, on: app).avatarHandle == nil)
        }
    }

    // MARK: - One handle in every course

    @Test func aStudentHasTheSameHandleInEveryCourse() async throws {
        try await withWebRoutesApp { app in
            let (cookie, student) = try await loggedInStudent(on: app)
            let second = try await makeTestCourse(on: app, code: "HC202")
            try await APICourseEnrollment(
                userID: try student.requireID(), courseID: try second.requireID(), role: .student
            ).save(on: app.db)
            _ = try await getResponse("/account", cookie: cookie, on: app)
            let handle = try #require(try await storedUser(student, on: app).avatarHandle)
            let enrollments = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == student.requireID()).all()
            #expect(enrollments.count == 2)
            for enrollment in enrollments {
                #expect(try await AvatarStore.ensureHandle(for: enrollment, on: app.db) == handle)
            }
        }
    }

    // MARK: - No lock

    private func visibleLeaderboard(setupID: String, on app: Application) async throws {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            language: nil,
            activity: ClassActivity(kind: .bestMetric, leaderboardVisibility: .visible))
        let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
        let setup = try await wrInsertSetup(id: setupID, manifest: manifest, on: app)
        _ = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: setup.courseID, title: "Race \(setupID)")
    }

    private func rank(_ user: APIUser, setupID: String, metric: Double, on app: Application) async throws {
        try await APILeaderboardEntry(
            testSetupID: setupID, userID: try user.requireID(),
            submissionID: "\(setupID)_\(user.username)", metric: metric, reachedAt: Date()
        ).save(on: app.db)
    }

    /// A classmate's view shows the handle and changes nothing about it: no
    /// handle locks, because nothing a student chooses depends on a lock.
    @Test func aClassmatesViewShowsTheHandleAndChangesNothing() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let viewer = try await wrStudentUser(on: app)
            try await wrEnrollUser(viewer, on: app)
            let mate = try await makeTestUser(on: app, username: "hc_ranked", role: "student")
            try await wrEnrollUser(mate, on: app)
            try await visibleLeaderboard(setupID: "hc_view", on: app)
            try await rank(mate, setupID: "hc_view", metric: 42, on: app)
            try await rank(viewer, setupID: "hc_view", metric: 7, on: app)

            let html = try await getResponse("/testsetups/hc_view/leaderboard", cookie: cookie, on: app).body.string
            let mateHandle = try #require(try await storedUser(mate, on: app).avatarHandle)
            #expect(html.contains(mateHandle))
            let mateEnrollment = try #require(
                try await APICourseEnrollment.query(on: app.db).filter(\.$userID == mate.requireID()).first())
            #expect(mateEnrollment.legacyAvatarHandleLockedAt == nil)
        }
    }
}
