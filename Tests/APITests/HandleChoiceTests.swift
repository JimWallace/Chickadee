// Tests/APITests/HandleChoiceTests.swift
//
// A student's one choice of class handle (docs/student-avatars.md §3): the
// account page offers the current handle and two unused alternates while the
// handle is unlocked; a pick saves and locks it; a pick someone else took
// first deals two new alternates; and the first time a classmate sees the
// handle on a student-visible leaderboard, it locks.  Staff views lock nothing.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct HandleChoiceTests {

    // MARK: - Helpers

    /// The student logged in and enrolled in the default course. Returns the
    /// session cookie, carrying a CSRF token, and the enrollment.
    private func loggedInStudent(on app: Application) async throws -> (cookie: String, enrollment: APICourseEnrollment)
    {
        let cookie = try await wrLoginAsStudent(on: app)
        let student = try await wrStudentUser(on: app)
        try await wrEnrollUser(student, on: app)
        let enrollment = try #require(
            try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == student.requireID())
                .first())
        return (cookie, enrollment)
    }

    /// The alternates the account page offered: every `handle` radio except
    /// the one checked, which is the current handle.
    private func offeredHandles(in html: String) -> [String] {
        html.components(separatedBy: "name=\"handle\" value=\"").dropFirst().compactMap { chunk in
            let parts = chunk.split(separator: "\"", maxSplits: 1)
            guard let value = parts.first, !(parts.last ?? "").hasPrefix(" checked") else { return nil }
            return String(value)
        }
    }

    private func choose(
        _ handle: String, courseID: UUID, cookie: String, on app: Application
    ) async throws -> TestingHTTPResponse {
        let form = try await csrfFields(for: "/account", cookie: cookie, on: app)
        return try await choose(handle, courseID: courseID, form: form, on: app)
    }

    /// The POST alone, with a token fetched earlier: the page a student has
    /// open, submitted after the world moved.
    private func choose(
        _ handle: String, courseID: UUID, form: (token: String, cookie: String), on app: Application
    ) async throws -> TestingHTTPResponse {
        let (token, newCookie) = form
        var captured: TestingHTTPResponse?
        try await app.asyncTest(
            .POST, "/account/handle/\(courseID.uuidString)",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: newCookie)
                try req.content.encode(["_csrf": token, "handle": handle], as: .urlEncodedForm)
            },
            afterResponse: { res in captured = res })
        return try #require(captured)
    }

    private func storedEnrollment(
        _ enrollment: APICourseEnrollment, on app: Application
    ) async throws
        -> APICourseEnrollment
    {
        try #require(try await APICourseEnrollment.find(enrollment.id, on: app.db))
    }

    // MARK: - The account page

    /// An ended course offers no handle change, and a change posted from a
    /// page opened before it ended is refused: an old handle ages out (#2258).
    @Test func anEndedCourseOffersNoChangeAndRefusesOne() async throws {
        try await withWebRoutesApp { app in
            let (cookie, enrollment) = try await loggedInStudent(on: app)
            let html = try await getResponse("/account", cookie: cookie, on: app).body.string
            let pick = try #require(offeredHandles(in: html).first)

            let course = try #require(try await APICourse.find(enrollment.$course.id, on: app.db))
            course.isArchived = true
            try await course.save(on: app.db)

            let res = try await choose(pick, courseID: try course.requireID(), cookie: cookie, on: app)
            #expect(res.status == .seeOther)
            let stored = try await storedEnrollment(enrollment, on: app)
            #expect(stored.avatarHandle != pick)
            #expect(stored.avatarHandleLockedAt == nil)

            let after = try await getResponse("/account", cookie: cookie, on: app).body.string
            #expect(offeredHandles(in: after).isEmpty)
        }
    }

    @Test func anUnlockedHandleIsOfferedTwoUnusedAlternates() async throws {
        try await withWebRoutesApp { app in
            let (cookie, enrollment) = try await loggedInStudent(on: app)
            // A classmate's handle, which must never be offered.
            let mate = try await makeTestUser(on: app, username: "hc_mate", role: "student")
            try await wrEnrollUser(mate, on: app)

            let html = try await getResponse("/account", cookie: cookie, on: app).body.string
            #expect(html.contains("Change handle"))
            let offered = offeredHandles(in: html)
            #expect(offered.count == 2)
            #expect(Set(offered).count == 2)

            let taken = try await AvatarStore.takenHandles(inCourse: enrollment.$course.id, on: app.db)
            for handle in offered {
                #expect(AvatarHandle.isWellFormed(handle))
                #expect(!taken.contains(handle), "\(handle) is already stored in the course")
            }
        }
    }

    /// Reloading the page does not deal a new pair: the choice is from three,
    /// not from as many as a student cares to reload.
    @Test func reloadingKeepsTheSameAlternates() async throws {
        try await withWebRoutesApp { app in
            let (cookie, _) = try await loggedInStudent(on: app)
            let first = offeredHandles(in: try await getResponse("/account", cookie: cookie, on: app).body.string)
            let second = offeredHandles(in: try await getResponse("/account", cookie: cookie, on: app).body.string)
            #expect(first.count == 2)
            #expect(first == second)
        }
    }

    @Test func pickingAnAlternateSavesItAndLocksIt() async throws {
        try await withWebRoutesApp { app in
            let (cookie, enrollment) = try await loggedInStudent(on: app)
            let offered = offeredHandles(in: try await getResponse("/account", cookie: cookie, on: app).body.string)
            let pick = try #require(offered.first)

            let res = try await choose(pick, courseID: enrollment.$course.id, cookie: cookie, on: app)
            #expect(res.status == .seeOther)
            let stored = try await storedEnrollment(enrollment, on: app)
            #expect(stored.avatarHandle == pick)
            #expect(stored.avatarHandleLockedAt != nil)

            // One change, full stop: the row says so and offers nothing.
            let html = try await getResponse("/account", cookie: cookie, on: app).body.string
            #expect(html.contains("Class handle: \(pick)"))
            #expect(html.contains("Your handle is set for this course."))
            #expect(!html.contains("Change handle"))
        }
    }

    @Test func aSecondChangeIsRefused() async throws {
        try await withWebRoutesApp { app in
            let (cookie, enrollment) = try await loggedInStudent(on: app)
            let offered = offeredHandles(in: try await getResponse("/account", cookie: cookie, on: app).body.string)
            let first = try #require(offered.first)
            let second = try #require(offered.last)
            _ = try await choose(first, courseID: enrollment.$course.id, cookie: cookie, on: app)

            _ = try await choose(second, courseID: enrollment.$course.id, cookie: cookie, on: app)
            #expect(try await storedEnrollment(enrollment, on: app).avatarHandle == first)
        }
    }

    /// Saving with the current handle still selected keeps it and does not
    /// spend the one change.
    @Test func savingTheCurrentHandleSpendsNothing() async throws {
        try await withWebRoutesApp { app in
            let (cookie, enrollment) = try await loggedInStudent(on: app)
            _ = try await getResponse("/account", cookie: cookie, on: app)
            let current = try #require(try await storedEnrollment(enrollment, on: app).avatarHandle)

            _ = try await choose(current, courseID: enrollment.$course.id, cookie: cookie, on: app)
            let stored = try await storedEnrollment(enrollment, on: app)
            #expect(stored.avatarHandle == current)
            #expect(stored.avatarHandleLockedAt == nil)
        }
    }

    /// A handle the page did not offer changes nothing, even one that is free.
    @Test func aHandleThatWasNotOfferedIsIgnored() async throws {
        try await withWebRoutesApp { app in
            let (cookie, enrollment) = try await loggedInStudent(on: app)
            let html = try await getResponse("/account", cookie: cookie, on: app).body.string
            let before = try await storedEnrollment(enrollment, on: app).avatarHandle
            let offered = Set(offeredHandles(in: html))
            let taken = try await AvatarStore.takenHandles(inCourse: enrollment.$course.id, on: app.db)
            let unoffered = try #require(AvatarHandle.make(excluding: taken.union(offered)))

            _ = try await choose(unoffered, courseID: enrollment.$course.id, cookie: cookie, on: app)
            let stored = try await storedEnrollment(enrollment, on: app)
            #expect(stored.avatarHandle == before)
            #expect(stored.avatarHandleLockedAt == nil)
        }
    }

    /// A pick that arrives after the handle was locked (a stale tab, or a
    /// second submit) changes nothing, and the row says so (#1763).
    @Test func aPickAfterTheLockIsReportedAsLocked() async throws {
        try await withWebRoutesApp { app in
            let (cookie, enrollment) = try await loggedInStudent(on: app)
            let form = try await csrfFields(for: "/account", cookie: cookie, on: app)
            let offered = offeredHandles(
                in: try await getResponse("/account", cookie: form.cookie, on: app).body.string)
            let pick = try #require(offered.first)
            // The lock lands between the page and the post.
            let locked = try await storedEnrollment(enrollment, on: app)
            locked.avatarHandleLockedAt = Date()
            try await locked.save(on: app.db)
            let before = locked.avatarHandle

            let res = try await choose(pick, courseID: enrollment.$course.id, form: form, on: app)
            #expect(res.status == .seeOther)
            let location = res.headers.first(name: .location) ?? ""
            #expect(location.contains("handleLocked="))
            #expect(try await storedEnrollment(enrollment, on: app).avatarHandle == before)

            let html = try await getResponse(location, cookie: form.cookie, on: app).body.string
            #expect(html.contains("Your handle is set for this course."))
            #expect(html.contains("It was set before your last choice arrived."))
        }
    }

    /// Alternates are not reserved. When a classmate stores the one picked
    /// first, nothing changes, and the page says so and deals two new ones.
    @Test func aPickTakenByAClassmateDealsTwoNewAlternates() async throws {
        try await withWebRoutesApp { app in
            let (cookie, enrollment) = try await loggedInStudent(on: app)
            // The page the student has open: its token and its offer.
            let form = try await csrfFields(for: "/account", cookie: cookie, on: app)
            let offered = offeredHandles(
                in: try await getResponse("/account", cookie: form.cookie, on: app).body.string)
            let pick = try #require(offered.first)
            let before = try await storedEnrollment(enrollment, on: app).avatarHandle

            let mate = try await makeTestUser(on: app, username: "hc_racer", role: "student")
            try await wrEnrollUser(mate, on: app)
            let mateEnrollment = try #require(
                try await APICourseEnrollment.query(on: app.db).filter(\.$userID == mate.requireID()).first())
            mateEnrollment.avatarHandle = pick
            try await mateEnrollment.save(on: app.db)

            let res = try await choose(pick, courseID: enrollment.$course.id, form: form, on: app)
            #expect(res.status == .seeOther)
            let location = res.headers.first(name: .location) ?? ""
            #expect(location.contains("handleTaken="))
            let stored = try await storedEnrollment(enrollment, on: app)
            #expect(stored.avatarHandle == before)
            #expect(stored.avatarHandleLockedAt == nil)

            let html = try await getResponse(location, cookie: form.cookie, on: app).body.string
            #expect(html.contains("That one was just taken. Here are two more."))
            let fresh = offeredHandles(in: html)
            #expect(fresh.count == 2)
            #expect(!fresh.contains(pick))
        }
    }

    // MARK: - The lock

    private func visibleLeaderboard(setupID: String, on app: Application) async throws {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
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

    private func enrollment(of user: APIUser, on app: Application) async throws -> APICourseEnrollment {
        try #require(
            try await APICourseEnrollment.query(on: app.db).filter(\.$userID == user.requireID()).first())
    }

    /// A classmate's view locks every handle it shows except the viewer's own.
    @Test func aStudentVisibleLeaderboardLocksTheHandlesItShowsToAClassmate() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let viewer = try await wrStudentUser(on: app)
            try await wrEnrollUser(viewer, on: app)
            let mate = try await makeTestUser(on: app, username: "hc_ranked", role: "student")
            try await wrEnrollUser(mate, on: app)
            try await visibleLeaderboard(setupID: "hc_lock", on: app)
            try await rank(mate, setupID: "hc_lock", metric: 42, on: app)
            try await rank(viewer, setupID: "hc_lock", metric: 7, on: app)

            #expect(try await getResponse("/testsetups/hc_lock/leaderboard", cookie: cookie, on: app).status == .ok)
            #expect(try await enrollment(of: mate, on: app).avatarHandleLockedAt != nil)
            #expect(try await enrollment(of: viewer, on: app).avatarHandleLockedAt == nil)
        }
    }

    @Test func aStaffViewLocksNothing() async throws {
        try await withWebRoutesApp { app in
            _ = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrEnrollUser(student, on: app)
            try await visibleLeaderboard(setupID: "hc_staff", on: app)
            try await rank(student, setupID: "hc_staff", metric: 3, on: app)

            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)

            let res = try await getResponse("/testsetups/hc_staff/leaderboard", cookie: cookie, on: app)
            #expect(res.status == .ok)
            let stored = try await enrollment(of: student, on: app)
            #expect(stored.avatarHandle != nil)
            #expect(stored.avatarHandleLockedAt == nil)
        }
    }
}
