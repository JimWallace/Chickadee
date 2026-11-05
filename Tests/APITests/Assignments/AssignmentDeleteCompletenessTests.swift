// Tests/APITests/Assignments/AssignmentDeleteCompletenessTests.swift
//
// #2809: deleting an assignment removes what the course purge removes for
// that assignment. That includes its submission files and the rows keyed by
// its setup or by the assignment that name students. Rows of another
// assignment stay.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5)))
struct AssignmentDeleteCompletenessTests {

    @Test func deletingAnAssignmentRemovesItsStudentRowsAndSubmissionFiles() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let student = try await makeTestStudent(on: app, username: "completeness_student")
            let studentID = try student.requireID()

            try await makeTestSetup(on: app, id: "setup_gone", courseID: courseID)
            let gone = try await makeTestAssignment(on: app, testSetupID: "setup_gone", courseID: courseID)
            try await makeTestSetup(on: app, id: "setup_kept", courseID: courseID)
            let kept = try await makeTestAssignment(
                on: app, testSetupID: "setup_kept", courseID: courseID, title: "Kept")

            var submissions: [String: APISubmission] = [:]
            for (setupID, assignment) in [("setup_gone", gone), ("setup_kept", kept)] {
                let submission = try await makeTestSubmission(
                    on: app, id: "sub_\(setupID)", setupID: setupID, userID: studentID)
                submissions[setupID] = submission
                try await makeTestResult(on: app, submissionID: try submission.requireID())
                try await APIClassCoverageRun(
                    testSetupID: setupID, submissionID: try submission.requireID(), contributors: [studentID]
                ).create(on: app.db)
                try await APIClassItemCoverage(
                    testSetupID: setupID, item: "variant_1", userID: studentID,
                    submissionID: try submission.requireID()
                ).create(on: app.db)
                try await APIDatasetDeal(
                    assignmentID: try assignment.requireID(), userID: studentID, dealNumber: 0
                ).create(on: app.db)
                try await APICompositeContribution(
                    assignmentID: try assignment.requireID(), userID: studentID, slot: 0,
                    submissionID: try submission.requireID(), submittedAt: Date(),
                    contribution: CompositeContribution(
                        width: 2, height: 1, frames: 1, format: .gray8,
                        data: Data([10, 200]).base64EncodedString()),
                    passed: true
                ).create(on: app.db)
            }
            let goneSubmission = try #require(submissions["setup_gone"])
            let keptSubmission = try #require(submissions["setup_kept"])
            #expect(FileManager.default.fileExists(atPath: goneSubmission.zipPath))

            try await app.asyncTest(
                .POST, "/instructor/\(gone.publicID)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            #expect(try await APIAssignment.find(gone.id, on: app.db) == nil)
            #expect(try await APISubmission.query(on: app.db).all().map(\.testSetupID) == ["setup_kept"])
            #expect(try await APIClassCoverageRun.query(on: app.db).all().map(\.testSetupID) == ["setup_kept"])
            #expect(try await APIClassItemCoverage.query(on: app.db).all().map(\.testSetupID) == ["setup_kept"])
            #expect(
                try await APIDatasetDeal.query(on: app.db).all().map(\.assignmentID) == [try kept.requireID()])
            #expect(
                try await APICompositeContribution.query(on: app.db).all().map(\.assignmentID)
                    == [try kept.requireID()])
            // The deleted assignment's submission file is gone after the
            // commit; the other assignment's file stays.
            #expect(!FileManager.default.fileExists(atPath: goneSubmission.zipPath))
            #expect(FileManager.default.fileExists(atPath: keptSubmission.zipPath))
        }
    }

    @Test func theSharedHelperReturnsSubmissionPathsAndRemovesNoFile() async throws {
        try await withTestApp { app in
            let course = try await makeTestCourse(on: app, code: "SHARED101")
            let courseID = try course.requireID()
            let student = try await makeTestStudent(on: app, username: "shared_student")
            try await makeTestSetup(on: app, id: "setup_shared", courseID: courseID)
            let submission = try await makeTestSubmission(
                on: app, id: "sub_shared", setupID: "setup_shared", userID: try student.requireID())

            let work = try await app.db.transaction { db in
                try await SetupRowDeletion.deleteStudentWork(forSetups: ["setup_shared"], on: db)
            }

            #expect(work.submissionCount == 1)
            #expect(work.filePaths == [submission.zipPath])
            #expect(try await APISubmission.query(on: app.db).count() == 0)
            #expect(FileManager.default.fileExists(atPath: submission.zipPath))
        }
    }

    @Test func theSharedHelperDoesNothingForNoSetups() async throws {
        try await withTestApp { app in
            let work = try await SetupRowDeletion.deleteStudentWork(forSetups: [], on: app.db)
            #expect(work.submissionCount == 0)
            #expect(work.filePaths.isEmpty)
        }
    }
}
