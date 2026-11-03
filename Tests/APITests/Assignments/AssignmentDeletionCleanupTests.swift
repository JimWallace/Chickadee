// Tests/APITests/Assignments/AssignmentDeletionCleanupTests.swift
//
// #2809: deleting an assignment removes what the course purge removes for it:
// the submission files after the commit, and the setup-keyed class, composite
// and dataset-deal rows, several of which name the contributing student.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5)))
struct AssignmentDeletionCleanupTests {

    /// One assignment with a student submission and a row in every table
    /// that `SetupRowDeletion` clears.
    struct Seed {
        let setupID: String
        let assignment: APIAssignment
        let submission: APISubmission
    }

    private func seed(
        on app: Application, courseID: UUID, setupID: String, student: APIUser
    ) async throws -> Seed {
        try await makeTestSetup(on: app, id: setupID, courseID: courseID)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: "Lab \(setupID)")
        let assignmentID = try assignment.requireID()
        let userID = try student.requireID()
        let submission = try await makeTestSubmission(
            on: app, id: "sub_\(setupID)", setupID: setupID, userID: userID)
        let submissionID = try submission.requireID()
        try await makeTestResult(on: app, submissionID: submissionID)

        try await APIClassCoverageRun(testSetupID: setupID, submissionID: submissionID, contributors: [userID])
            .create(on: app.db)
        try await APIClassItemCoverage(
            testSetupID: setupID, item: "item_a", userID: userID, submissionID: submissionID
        ).create(on: app.db)
        try await APIAchievementResult(
            testSetupID: setupID, achievementID: "goal", studentsMeeting: 1, denominator: 1,
            progress: 1, locked: false, evaluatedAt: Date()
        ).create(on: app.db)
        try await APICompositeContribution(
            assignmentID: assignmentID, userID: userID, slot: 0, submissionID: submissionID,
            submittedAt: Date(),
            contribution: CompositeContribution(
                width: 2, height: 1, frames: 1, format: .gray8, data: Data([0, 255]).base64EncodedString()),
            passed: true
        ).create(on: app.db)
        try await APIDatasetDeal(assignmentID: assignmentID, userID: userID, dealNumber: 0)
            .create(on: app.db)
        return Seed(setupID: setupID, assignment: assignment, submission: submission)
    }

    /// The number of rows the seed put in each cleared table that still name
    /// the seed's setup or assignment.
    private func remainingRows(_ seed: Seed, on app: Application) async throws -> [String: Int] {
        let assignmentID = try seed.assignment.requireID()
        return [
            "submissions": try await APISubmission.query(on: app.db)
                .filter(\.$testSetupID == seed.setupID).count(),
            "results": try await APIResult.query(on: app.db)
                .filter(\.$submissionID == seed.submission.requireID()).count(),
            "coverageRuns": try await APIClassCoverageRun.query(on: app.db)
                .filter(\.$testSetupID == seed.setupID).count(),
            "itemCoverage": try await APIClassItemCoverage.query(on: app.db)
                .filter(\.$testSetupID == seed.setupID).count(),
            "goalSnapshots": try await APIAchievementResult.query(on: app.db)
                .filter(\.$testSetupID == seed.setupID).count(),
            "compositeContributions": try await APICompositeContribution.query(on: app.db)
                .filter(\.$assignmentID == assignmentID).count(),
            "datasetDeals": try await APIDatasetDeal.query(on: app.db)
                .filter(\.$assignmentID == assignmentID).count(),
        ]
    }

    @Test func assignmentDeleteRemovesTheClassCompositeAndDealRowsAndOnlyThose() async throws {
        try await withTestApp { app in
            let course = try await makeTestCourse(on: app, code: "CLEAN101")
            let courseID = try course.requireID()
            let student = try await makeTestStudent(on: app, username: "clean_student")
            let doomed = try await seed(on: app, courseID: courseID, setupID: "setup_clean_doomed", student: student)
            let kept = try await seed(on: app, courseID: courseID, setupID: "setup_clean_kept", student: student)

            let removed = try await app.db.transaction { db in
                try await AssignmentDeletion.deleteRows(of: doomed.assignment, on: db)
            }

            #expect(removed.submissionCount == 1)
            #expect(removed.filePaths.contains(doomed.submission.zipPath))
            #expect(try await remainingRows(doomed, on: app).values.allSatisfy { $0 == 0 })
            // The other assignment in the same course keeps every row.
            #expect(try await remainingRows(kept, on: app).values.allSatisfy { $0 == 1 })
        }
    }

    @Test func assignmentDeleteRemovesValidationVariantsWhenTheSetupHasNoSubmissions() async throws {
        try await withTestApp { app in
            let course = try await makeTestCourse(on: app, code: "CLEAN102")
            let courseID = try course.requireID()
            try await makeTestSetup(on: app, id: "setup_clean_variants", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_clean_variants", courseID: courseID)
            try await ValidationVariant(
                testSetupID: "setup_clean_variants", variantIndex: 0, seedHex: "00", submissionID: nil
            ).create(on: app.db)

            _ = try await app.db.transaction { db in
                try await AssignmentDeletion.deleteRows(of: assignment, on: db)
            }

            let variants = try await ValidationVariant.query(on: app.db)
                .filter(\.$testSetupID == "setup_clean_variants").count()
            #expect(variants == 0)
        }
    }

    @Test func assignmentDeleteRouteRemovesTheSubmissionFilesAfterTheCommit() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let student = try await makeTestStudent(on: app, username: "clean_route_student")
            let seed = try await seed(on: app, courseID: courseID, setupID: "setup_clean_route", student: student)
            #expect(FileManager.default.fileExists(atPath: seed.submission.zipPath))

            try await app.asyncTest(
                .POST, "/instructor/\(seed.assignment.publicID)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            #expect(try await APIAssignment.find(seed.assignment.id, on: app.db) == nil)
            #expect(!FileManager.default.fileExists(atPath: seed.submission.zipPath))
        }
    }
}
