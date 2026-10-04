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

    // MARK: - What the Students tab shows

    /// The sweep stores a full sentence, so the Students tab must not put the
    /// stored detail in the badge. The two kinds of unreachable student also
    /// need different advice: only a student whose ID LEARN does not list is a
    /// candidate for removal, and a student with no ID needs one added.
    @Test func studentsTabShowsAShortBadgeAndTheRightAdviceForWhatTheSweepStored() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let course = try #require(try await APICourse.find(courseID, on: app.db))

            // A student ID that the classlist does not list: not on LEARN.
            let dropped = try await arInsertStudent(username: "sweep_dropped", on: app)
            dropped.studentID = "20999999"
            try await dropped.save(on: app.db)
            try await arEnrollStudentInTestCourse(dropped, on: app)
            // No student ID, and the classlist does not list the username.
            let unmatched = try await arInsertStudent(username: "sweep_unmatched", on: app)
            try await arEnrollStudentInTestCourse(unmatched, on: app)

            let client = FakeReadinessClient(classlist: [
                BrightSpaceClasslistEntry(orgDefinedID: "20000001", username: "someone_else", userID: "d2l-9")
            ])
            let outcome = try await reconcileCourseReadiness(
                course: course, orgUnitID: "12345", client: client,
                on: app.db, application: app)
            #expect(outcome.unreachable == 2)

            var html = ""
            try await app.asyncTest(
                .GET, "/instructor/students",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    html = res.body.string
                })

            // The rest of a student's row, from the name cell to the row end.
            func row(_ username: String) throws -> Substring {
                let start = try #require(html.range(of: "data-sort-value=\"\(username)\""))
                let end = try #require(html.range(of: "</tr>", range: start.upperBound..<html.endIndex))
                return html[start.upperBound..<end.lowerBound]
            }
            let droppedRow = try row("sweep_dropped")
            #expect(droppedRow.contains(">Not on LEARN</span>"))
            #expect(droppedRow.contains("Remove from course if confirmed dropped"))
            #expect(!droppedRow.contains("Add a student ID"))
            let unmatchedRow = try row("sweep_unmatched")
            #expect(unmatchedRow.contains(">No LEARN match</span>"))
            #expect(unmatchedRow.contains("Add a student ID to match LEARN"))
            #expect(!unmatchedRow.contains("if confirmed dropped"))
        }
    }

    /// A badge is a label of two or three words (docs/ui-design.md, "UI copy").
    @Test(arguments: LearnUnreachableReason.allCases)
    func everyLearnBadgeIsAShortLabel(_ reason: LearnUnreachableReason) {
        let words = reason.badge.split(separator: " ").count
        #expect((2...3).contains(words))
        #expect(reason.badge != reason.storedDetail)
        #expect(LearnUnreachableReason(storedDetail: reason.storedDetail) == reason)
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
