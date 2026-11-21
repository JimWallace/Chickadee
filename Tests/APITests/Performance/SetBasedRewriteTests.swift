// Tests/APITests/Performance/SetBasedRewriteTests.swift
//
// The reads and writes that moved from a Swift loop into one SQL statement
// keep the answers the loop gave: the newest complete submission per enrolled
// student, the chart bucket of an event at either edge of the window, a
// pending start time that is already set, and the sync flags a bulk requeue
// or clear writes to each table.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5)))
struct SetBasedRewriteTests {

    // MARK: - latestStudentSubmissionsByUser

    @Test func theLatestPickIsTheNewestCompleteSubmissionOfEachEnrolledStudent() async throws {
        try await withTestApp(prefix: "chickadee-latest-pick") { app in
            let course = try await makeTestCourse(on: app, code: "PICK101")
            let courseID = try course.requireID()
            let setup = try await makeTestSetup(on: app, id: "setup_latest_pick", courseID: courseID)
            let first = try await makeTestStudent(on: app, username: "pick_first")
            let second = try await makeTestStudent(on: app, username: "pick_second")
            let dropped = try await makeTestStudent(on: app, username: "pick_dropped")
            for student in [first, second] {
                try await makeTestEnrollment(on: app, userID: try student.requireID(), courseID: courseID)
            }

            func submit(_ id: String, _ user: APIUser, minute: Int, status: String = "complete") async throws {
                let row = try await makeTestSubmission(
                    on: app, id: id, setupID: "setup_latest_pick", userID: try user.requireID(), status: status)
                row.submittedAt = Date(timeIntervalSince1970: 1_000_000 + Double(minute * 60))
                try await row.save(on: app.db)
            }
            try await submit("pick_first_1", first, minute: 1)
            try await submit("pick_first_3", first, minute: 3)
            // Newer, but not complete: not the pick.
            try await submit("pick_first_4", first, minute: 4, status: "pending")
            try await submit("pick_second_2", second, minute: 2)
            // Not enrolled: not in the result at all.
            try await submit("pick_dropped_5", dropped, minute: 5)

            let picked = try await latestStudentSubmissionsByUser(setup: setup, on: app.db)
            #expect(picked.count == 2)
            #expect(picked[try first.requireID()]?.id == "pick_first_3")
            #expect(picked[try second.requireID()]?.id == "pick_second_2")
            // The whole row loads, not only its id.
            #expect(picked[try first.requireID()]?.zipPath.isEmpty == false)

            let others = try await latestStudentSubmissionsByUser(
                setup: setup, excluding: try first.requireID(), on: app.db)
            #expect(Set(others.keys) == [try second.requireID()])
        }
    }

    // MARK: - Activity chart buckets

    @Test func anEventAtEitherEdgeOfTheWindowLandsInTheEdgeBucket() async throws {
        try await withTestApp(prefix: "chickadee-chart-edges") { app in
            let user = try await makeTestUser(on: app, username: "chart_edge_user")
            let other = try await makeTestUser(on: app, username: "chart_edge_other")
            let now = Date(timeIntervalSince1970: 2_000_000)
            let window = ActivityWindow.day
            for (userID, time) in [
                (try user.requireID(), now),
                (try other.requireID(), now.addingTimeInterval(-window.totalSeconds)),
            ] {
                let event = APIUserActivityEvent(userID: userID, role: "student")
                try await event.save(on: app.db)
                event.createdAt = time
                try await event.save(on: app.db)
            }

            let data = try await UserActivityChartService.chartData(window: window, on: app.db, now: now)
            // Exactly `now` is clamped into the last bucket; exactly the
            // window start is the first.
            #expect(data.buckets.last?.count == 1)
            #expect(data.buckets.first?.count == 1)
            #expect(data.buckets.reduce(0) { $0 + $1.count } == 2)
        }
    }

    // MARK: - BrightSpace sync flags

    private struct Graded {
        let results: [APIResult]
        let override: APIGradeOverride
    }

    /// One student with two graded submissions and an override on a setup.
    private func graded(_ app: Application, prefix: String) async throws -> Graded {
        let course = try await makeTestCourse(on: app, code: "\(prefix.uppercased())101")
        let setupID = "setup_\(prefix)"
        try await makeTestSetup(on: app, id: setupID, courseID: try course.requireID())
        let student = try await makeTestStudent(on: app, username: "\(prefix)_student")
        var results: [APIResult] = []
        for index in 1...2 {
            let submission = try await makeTestSubmission(
                on: app, id: "\(prefix)_sub_\(index)", setupID: setupID, userID: try student.requireID())
            results.append(try await makeTestResult(on: app, submissionID: try submission.requireID()))
        }
        let override = APIGradeOverride(
            testSetupID: setupID, userID: try student.requireID(), overridePercent: 80, note: nil,
            grantedByUserID: nil)
        try await override.save(on: app.db)
        return Graded(results: results, override: override)
    }

    @Test func flaggingAStudentKeepsAPendingStartThatIsAlreadySet() async throws {
        try await withTestApp(prefix: "chickadee-flag-student") { app in
            let fixture = try await graded(app, prefix: "flagkeep")
            let earlier = Date(timeIntervalSince1970: 1_500_000)
            fixture.results[0].brightspacePendingSince = earlier
            try await fixture.results[0].save(on: app.db)

            try await flagStudentForBrightSpaceSync(
                override: fixture.override, testSetupID: fixture.override.testSetupID,
                studentUserID: fixture.override.userID, on: app.db)

            let kept = try #require(try await APIResult.find(fixture.results[0].id, on: app.db))
            let fresh = try #require(try await APIResult.find(fixture.results[1].id, on: app.db))
            #expect(kept.brightspaceSyncPending == true)
            #expect(kept.brightspacePendingSince == earlier)
            #expect(fresh.brightspaceSyncPending == true)
            #expect((fresh.brightspacePendingSince ?? .distantPast) > earlier)
        }
    }

    @Test func aBulkRequeueAndClearWriteEveryRowOfEachTable() async throws {
        try await withTestApp(prefix: "chickadee-sync-flags") { app in
            let fixture = try await graded(app, prefix: "flagbulk")
            for result in fixture.results {
                result.brightspaceSyncError = "LEARN refused"
                try await result.save(on: app.db)
            }
            let rows: [any BrightSpaceSyncFlaggable] = fixture.results + [fixture.override]

            try await requeueForImmediateSync(rows, on: app.db)
            for result in fixture.results {
                let stored = try #require(try await APIResult.find(result.id, on: app.db))
                #expect(stored.brightspaceSyncPending == true)
                #expect(stored.brightspacePendingSince == Date.distantPast)
                #expect(stored.brightspaceSyncError == nil)
            }
            let requeued = try #require(try await APIGradeOverride.find(fixture.override.id, on: app.db))
            #expect(requeued.brightspaceSyncPending == true)
            #expect(requeued.brightspacePendingSince == Date.distantPast)

            try await clearPendingFlag(rows, on: app.db)
            for result in fixture.results {
                #expect(try await APIResult.find(result.id, on: app.db)?.brightspaceSyncPending == false)
            }
            #expect(try await APIGradeOverride.find(fixture.override.id, on: app.db)?.brightspaceSyncPending == false)
        }
    }
}
