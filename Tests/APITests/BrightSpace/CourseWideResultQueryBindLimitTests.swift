// Tests/APITests/BrightSpace/CourseWideResultQueryBindLimitTests.swift
//
// #2764: the course-wide result queries must not bind one parameter per
// submission. A driver refuses a statement past its bind limit: 65,535 on
// PostgreSQL (the wire protocol counts parameters in 16 bits), and 250,000 on
// the SQLite that sqlite-nio compiles. These tests seed more student
// submissions than the PostgreSQL limit and drive the LEARN tab summary and the
// "Sync now" re-queue over them. On the PostgreSQL lane the unchunked queries
// fail; on SQLite the tests guard the query shape.

import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized, .timeLimit(.minutes(10)))
final class CourseWideResultQueryBindLimitTests {

    /// One more than PostgreSQL's bind-parameter limit (65,535).
    static let submissionCount = 65_536

    /// Rows per seeding INSERT. At 19 columns a row, 2,000 rows bind 38,000
    /// parameters: under the limit of either driver.
    static let seedBatchSize = 2_000

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-bindlimit")
    }

    private struct Seeded {
        let courseID: UUID
        let setupID: String
        let firstUserID: UUID
        let secondUserID: UUID
    }

    /// A course with one assignment and two students, with no submissions yet.
    private func seedCourse() async throws -> Seeded {
        let course = APICourse(code: "BIND101", name: "Bind Limit Course")
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        let setupID = "setup_bindlimit"
        try await APITestSetup(
            id: setupID, manifest: TestManifests.workerOnePythonSuite,
            zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID
        ).save(on: app.db)
        try await APIAssignment(
            testSetupID: setupID, title: "Bind Limit Lab", dueAt: nil, isOpen: true, courseID: courseID
        ).save(on: app.db)
        let first = APIUser(username: "bindlimit-a", passwordHash: "", role: UserRole.user.rawValue)
        let second = APIUser(username: "bindlimit-b", passwordHash: "", role: UserRole.user.rawValue)
        try await first.save(on: app.db)
        try await second.save(on: app.db)
        return Seeded(
            courseID: courseID, setupID: setupID,
            firstUserID: try first.requireID(), secondUserID: try second.requireID())
    }

    /// Seeds `submissionCount` student submissions, split between the two
    /// students, each with one result row that `configure` shapes.
    private func seedSubmissions(
        _ seeded: Seeded,
        configure: (_ index: Int, _ isFirstStudent: Bool, _ result: APIResult) -> Void
    ) async throws {
        var start = 0
        while start < Self.submissionCount {
            let end = min(start + Self.seedBatchSize, Self.submissionCount)
            var submissions: [APISubmission] = []
            var results: [APIResult] = []
            for index in start..<end {
                let isFirst = index.isMultiple(of: 2)
                let submissionID = "sub_bl_\(index)"
                submissions.append(
                    APISubmission(
                        id: submissionID, testSetupID: seeded.setupID,
                        zipPath: app.submissionsDirectory + "\(submissionID).zip",
                        attemptNumber: index / 2 + 1,
                        status: SubmissionStatus.complete.rawValue,
                        userID: isFirst ? seeded.firstUserID : seeded.secondUserID))
                let result = APIResult(id: "res_bl_\(index)", submissionID: submissionID)
                configure(index, isFirst, result)
                results.append(result)
            }
            try await submissions.create(on: app.db)
            try await results.create(on: app.db)
            start = end
        }
    }

    @Test func theLearnTabSummaryReadsACoursePastTheBindLimit() async throws {
        try await withApp(app) { app in
            let seeded = try await seedCourse()
            let syncedAt = Date(timeIntervalSince1970: 1_700_000_000)
            // Every row of the first student errored; every row of the second
            // synced. Whichever row is latest, each student's state is fixed.
            try await seedSubmissions(seeded) { _, isFirst, result in
                if isFirst {
                    result.brightspaceSyncError = "LEARN refused the grade"
                } else {
                    result.brightspaceSyncedAt = syncedAt
                }
            }

            let (summary, perSetup) = try await BrightSpacePagePresenter.syncSummary(
                courseUUID: seeded.courseID, setupIDs: [seeded.setupID], on: app.db)

            #expect(summary.errored == 1)
            #expect(summary.synced == 1)
            #expect(summary.pending == 0)
            #expect(perSetup[seeded.setupID]?.errored == 1)
            #expect(perSetup[seeded.setupID]?.synced == 1)
        }
    }

    @Test func syncNowRequeuesOnlyTheErroredRowsOfACoursePastTheBindLimit() async throws {
        try await withApp(app) { app in
            let seeded = try await seedCourse()
            let erroredIndexes: Set<Int> = [0, 1, Self.submissionCount - 1]
            // A few rows errored; the rest carry no error, or an empty one,
            // which is not an error and must stay as it is.
            try await seedSubmissions(seeded) { index, _, result in
                if erroredIndexes.contains(index) {
                    result.brightspaceSyncError = "LEARN refused the grade"
                } else if index == 2 {
                    result.brightspaceSyncError = ""
                }
            }

            try await requeueErroredGradePushes(courseUUID: seeded.courseID, on: app.db)

            let stillErrored = try await APIResult.query(on: app.db)
                .filter(\.$brightspaceSyncError == "LEARN refused the grade")
                .count()
            #expect(stillErrored == 0)
            let requeued = try await APIResult.query(on: app.db)
                .filter(\.$brightspaceSyncPending == true)
                .all()
            #expect(Set(requeued.compactMap(\.id)) == Set(erroredIndexes.map { "res_bl_\($0)" }))
            let emptyError = try await APIResult.find("res_bl_2", on: app.db)
            #expect(emptyError?.brightspaceSyncError?.isEmpty == true)
            #expect(emptyError?.brightspaceSyncPending != true)
        }
    }
}
