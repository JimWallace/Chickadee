// Tests/APITests/LearnRosterReadinessTests.swift
//
// Covers the persistent LEARN roster-readiness layer: the per-course reconcile
// (classifies each enrolled student against the LEARN classlist and persists
// the status on the enrollment), and the manual "Reconcile now" route. The
// reconcile core takes the `BrightSpaceGrading` client as a seam, so it runs
// against an in-memory fake — no live D2L.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

/// Minimal `BrightSpaceGrading` fake — only `fetchClasslist` is meaningful for
/// readiness; the grade-push surface is unused here.
private struct FakeReadinessClient: BrightSpaceGrading {
    let classlist: [BrightSpaceClasslistEntry]

    func lookupUserID(orgDefinedId: String, on application: Application) async throws -> String? { nil }
    func fetchClasslist(
        orgUnitID: String, on application: Application
    ) async throws -> [BrightSpaceClasslistEntry] {
        classlist
    }
    func pushGrade(
        orgUnitID: String, gradeObjectID: String, bsUserID: String, earnedPoints: Double,
        on application: Application
    ) async throws {}
    func fetchGradeObject(
        orgUnitID: String, gradeObjectID: String, on application: Application
    ) async throws -> BrightSpaceGradeObject? { nil }
    func clearGrade(
        orgUnitID: String, gradeObjectID: String, bsUserID: String, on application: Application
    ) async throws {}
}

@Suite struct LearnRosterReadinessTests {

    // MARK: - Per-course reconcile

    @Test func reconcileClassifiesEnrolledStudentsAndPersists() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let course = try #require(try await APICourse.find(courseID, on: app.db))
            course.brightspaceOrgUnitID = "12345"
            try await course.save(on: app.db)

            // One student matches the LEARN classlist by username; the other
            // (no student ID, username not on the list) can't be delivered to.
            let matched = try await arInsertStudent(username: "match_user", on: app)
            try await arEnrollStudentInTestCourse(matched, on: app)
            let missed = try await arInsertStudent(username: "miss_user", on: app)
            try await arEnrollStudentInTestCourse(missed, on: app)

            let client = FakeReadinessClient(classlist: [
                BrightSpaceClasslistEntry(orgDefinedID: nil, username: "match_user", userID: "d2l-1")
            ])
            let outcome = try await reconcileCourseReadiness(
                course: course, orgUnitID: "12345", client: client,
                on: app.db, application: app)

            #expect(outcome.checked == 2)
            #expect(outcome.confirmed == 1)
            #expect(outcome.unreachable == 1)
            #expect(outcome.updated == 2)

            let matchEnroll = try #require(
                try await APICourseEnrollment.query(on: app.db)
                    .filter(\.$userID == matched.requireID()).first())
            #expect(matchEnroll.learnSyncReadiness == .confirmed)
            #expect(matchEnroll.brightspaceSyncDetail == nil)
            #expect(matchEnroll.brightspaceCheckedAt != nil)

            let missEnroll = try #require(
                try await APICourseEnrollment.query(on: app.db)
                    .filter(\.$userID == missed.requireID()).first())
            #expect(missEnroll.learnSyncReadiness == .unreachable)
            #expect((missEnroll.brightspaceSyncDetail ?? "").isEmpty == false)
        }
    }

    @Test func enrollmentReadinessDefaultsToUnconfirmed() async throws {
        try await withAssignmentRoutesApp { app in
            let student = try await arInsertStudent(username: "fresh_user", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            let enroll = try #require(
                try await APICourseEnrollment.query(on: app.db)
                    .filter(\.$userID == student.requireID()).first())
            // Never swept → NULL stored status reads as unconfirmed.
            #expect(enroll.learnSyncReadiness == .unconfirmed)
            #expect(enroll.brightspaceCheckedAt == nil)
        }
    }

    // MARK: - Reconcile-now route

    @Test func reconcileNowRedirectsWhenCourseUnlinked() async throws {
        try await withAssignmentRoutesApp { app in
            // Active course but no org unit bound → the route flashes + redirects
            // rather than attempting a classlist fetch.
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/instructor/brightspace/reconcile-now",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor/brightspace")
                })
        }
    }
}
