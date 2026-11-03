// Tests/APITests/Admin/PollQueryAggregateTests.swift
//
// Three pages poll every five seconds. Their queries now push the work into
// the database instead of loading whole tables (#2777). These tests pin that
// each new query gives the same answer as the one it replaced.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct PollQueryAggregateTests {

    // MARK: - Admin users: the staff ring

    /// `allCourseStaff` sends no user list. It must name the same users as
    /// `courseStaff(among:)` over every user ID, which the page used before.
    @Test func allCourseStaffMatchesCourseStaffOverEveryUser() async throws {
        try await withTestApp(prefix: "chickadee-poll-staff") { app in
            let current = try await makeTestCourse(on: app, code: "POLLNOW")
            let past = try await makeTestCourse(on: app, code: "POLLPAST", archived: true)
            let currentID = try current.requireID()
            let pastID = try past.requireID()

            func user(_ name: String) async throws -> UUID {
                try await makeTestUser(on: app, username: name).requireID()
            }
            let ta = try await user("poll_ta")
            let instructor = try await user("poll_instructor")
            let student = try await user("poll_student")
            let pastTA = try await user("poll_past_ta")
            let noCourse = try await user("poll_no_course")

            try await APICourseEnrollment(userID: ta, courseID: currentID, role: .ta).save(on: app.db)
            try await APICourseEnrollment(userID: instructor, courseID: currentID, role: .instructor)
                .save(on: app.db)
            try await APICourseEnrollment(userID: student, courseID: currentID, role: .student)
                .save(on: app.db)
            try await APICourseEnrollment(userID: pastTA, courseID: pastID, role: .ta).save(on: app.db)

            let everyone = try await APIUser.query(on: app.db).all().compactMap(\.id)
            let expected = try await AvatarStore.courseStaff(among: everyone, on: app.db)
            let actual = try await AvatarStore.allCourseStaff(on: app.db)

            #expect(actual == expected)
            #expect(actual == [ta, instructor])
            #expect(!actual.contains(student))
            #expect(!actual.contains(pastTA))
            #expect(!actual.contains(noCourse))
        }
    }

    // MARK: - Runners: per-worker job counts

    @Test func workerJobCountsReadOnlyKnownWorkersAndCountedStatuses() async throws {
        try await withTestApp(prefix: "chickadee-poll-runners") { app in
            let course = try await makeTestCourse(on: app, code: "POLLRUN")
            let setup = try await makeTestSetup(on: app, id: "setup_poll_runners", courseID: try course.requireID())
            let setupID = try setup.requireID()
            let studentID = try await makeTestUser(on: app, username: "poll_runner_student").requireID()

            func job(_ id: String, worker: String, status: String) async throws {
                let submission = try await makeTestSubmission(
                    on: app, id: id, setupID: setupID, userID: studentID, status: status)
                submission.workerID = worker
                try await submission.update(on: app.db)
            }
            try await job("sub_pr1", worker: "runner-A", status: "complete")
            try await job("sub_pr2", worker: "runner-A", status: "failed")
            try await job("sub_pr3", worker: "runner-A", status: "assigned")
            try await job("sub_pr4", worker: "runner-A", status: "pending")
            try await job("sub_pr5", worker: "runner-B", status: "assigned")
            try await job("sub_pr6", worker: "runner-gone", status: "complete")

            let counts = try await workerJobCounts(workerIDs: ["runner-A", "runner-B"], on: app.db)
            #expect(counts.assigned == ["runner-A": 1, "runner-B": 1])
            #expect(counts.processed == ["runner-A": 2])

            let none = try await workerJobCounts(workerIDs: [], on: app.db)
            #expect(none.assigned.isEmpty)
            #expect(none.processed.isEmpty)
        }
    }

    // MARK: - Leaderboard: per-student submission counts

    @Test func leaderboardSubmissionCountsCountStudentRowsPerUser() async throws {
        try await withTestApp(prefix: "chickadee-poll-board") { app in
            let course = try await makeTestCourse(on: app, code: "POLLBRD")
            let courseID = try course.requireID()
            let setup = try await makeTestSetup(on: app, id: "setup_poll_board", courseID: courseID)
            let other = try await makeTestSetup(on: app, id: "setup_poll_other", courseID: courseID)
            let setupID = try setup.requireID()
            let otherID = try other.requireID()
            let alice = try await makeTestUser(on: app, username: "poll_alice").requireID()
            let bob = try await makeTestUser(on: app, username: "poll_bob").requireID()

            try await makeTestSubmission(on: app, id: "sub_pb1", setupID: setupID, userID: alice)
            try await makeTestSubmission(on: app, id: "sub_pb2", setupID: setupID, userID: alice)
            try await makeTestSubmission(on: app, id: "sub_pb3", setupID: setupID, userID: alice)
            try await makeTestSubmission(on: app, id: "sub_pb4", setupID: setupID, userID: bob)
            // Not counted: another setup, and a staff validation run.
            try await makeTestSubmission(on: app, id: "sub_pb5", setupID: otherID, userID: bob)
            try await makeTestSubmission(
                on: app, id: "sub_pb6", setupID: setupID, userID: bob, kind: APISubmission.Kind.validation)

            let counts = try await leaderboardSubmissionCounts(setupID: setupID, on: app.db)
            #expect(counts == [alice: 3, bob: 1])
            #expect(try await leaderboardSubmissionCounts(setupID: "setup_poll_none", on: app.db).isEmpty)
        }
    }
}
