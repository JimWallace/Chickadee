// Tests/APITests/Assignments/DeletionAtomicityTests.swift
//
// #2766: the assignment delete and the course purge run their row deletes in
// one transaction and remove files only after it commits. A failure midway
// leaves every row in place and every file on disk.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5)))
struct DeletionAtomicityTests {

    /// The failure that the tests inject after the row deletes and before the
    /// commit.
    enum InjectedFailure: Error {
        case beforeCommit
    }

    /// A course with one setup (zip and notebook on disk), its assignment, and
    /// one student submission (file on disk) with a result.
    struct Seed {
        let course: APICourse
        let courseID: UUID
        let setup: APITestSetup
        let assignment: APIAssignment
        let submission: APISubmission
    }

    private func seed(on app: Application, code: String, setupID: String) async throws -> Seed {
        let course = try await makeTestCourse(on: app, code: code, archived: true)
        let courseID = try course.requireID()
        let setup = try await makeTestSetup(on: app, id: setupID, courseID: courseID)
        let assignment = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        let student = try await makeTestStudent(on: app, username: "student_\(setupID)")
        let submission = try await makeTestSubmission(
            on: app, id: "sub_\(setupID)", setupID: setupID, userID: try student.requireID())
        try await makeTestResult(on: app, submissionID: try submission.requireID())
        return Seed(
            course: course, courseID: courseID, setup: setup, assignment: assignment, submission: submission)
    }

    private func fileExists(_ path: String?) -> Bool {
        guard let path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Asserts that the seed's rows and files are all still present.
    private func expectIntact(_ seed: Seed, on app: Application) async throws {
        let setupID = try seed.setup.requireID()
        let submissionID = try seed.submission.requireID()
        #expect(try await APICourse.find(seed.courseID, on: app.db) != nil)
        #expect(try await APIAssignment.find(seed.assignment.id, on: app.db) != nil)
        #expect(try await APITestSetup.find(setupID, on: app.db) != nil)
        #expect(try await APISubmission.find(submissionID, on: app.db) != nil)
        let results = try await APIResult.query(on: app.db).filter(\.$submissionID == submissionID).count()
        #expect(results == 1)
        #expect(fileExists(seed.setup.zipPath))
        #expect(fileExists(seed.setup.notebookPath))
        #expect(fileExists(seed.submission.zipPath))
    }

    // MARK: - Assignment delete

    @Test func assignmentDeleteRollsBackEveryRowAndKeepsFilesWhenTheTransactionFails() async throws {
        try await withTestApp { app in
            let seed = try await seed(on: app, code: "ATOM101", setupID: "setup_atomic_assignment")

            await #expect(throws: InjectedFailure.self) {
                try await app.db.transaction { db in
                    _ = try await AssignmentDeletion.deleteRows(of: seed.assignment, on: db)
                    throw InjectedFailure.beforeCommit
                }
            }

            try await expectIntact(seed, on: app)
        }
    }

    @Test func assignmentDeleteReturnsTheSetupFilesAndRemovesNone() async throws {
        try await withTestApp { app in
            let seed = try await seed(on: app, code: "ATOM102", setupID: "setup_atomic_paths")

            let removed = try await app.db.transaction { db in
                try await AssignmentDeletion.deleteRows(of: seed.assignment, on: db)
            }

            #expect(removed.submissionCount == 1)
            #expect(removed.setupDeleted)
            #expect(Set(removed.filePaths) == Set([seed.setup.zipPath, seed.setup.notebookPath].compactMap(\.self)))
            // The rows are gone, but the helper itself touched no file.
            #expect(try await APIAssignment.find(seed.assignment.id, on: app.db) == nil)
            #expect(try await APITestSetup.find(seed.setup.id, on: app.db) == nil)
            #expect(try await APIResult.query(on: app.db).count() == 0)
            #expect(fileExists(seed.setup.zipPath))
            #expect(fileExists(seed.setup.notebookPath))
        }
    }

    @Test func assignmentDeleteRouteRemovesTheSetupFilesAfterTheCommit() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setup = try await makeTestSetup(on: app, id: "setup_atomic_route", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_atomic_route", courseID: courseID)
            #expect(fileExists(setup.zipPath))
            #expect(fileExists(setup.notebookPath))

            try await app.asyncTest(
                .POST, "/instructor/\(assignment.publicID)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            #expect(try await APIAssignment.find(assignment.id, on: app.db) == nil)
            #expect(try await APITestSetup.find(setup.id, on: app.db) == nil)
            #expect(!fileExists(setup.zipPath))
            #expect(!fileExists(setup.notebookPath))
        }
    }

    // MARK: - Course purge

    @Test func coursePurgeRollsBackEveryRowAndKeepsFilesWhenTheTransactionFails() async throws {
        try await withTestApp { app in
            let seed = try await seed(on: app, code: "ATOM201", setupID: "setup_atomic_course")

            await #expect(throws: InjectedFailure.self) {
                try await app.db.transaction { db in
                    _ = try await CoursePurge.deleteRows(
                        of: seed.course, setupsDirectory: app.testSetupsDirectory, on: db)
                    throw InjectedFailure.beforeCommit
                }
            }

            try await expectIntact(seed, on: app)
        }
    }

    @Test func coursePurgeReturnsTheSubmissionAndSetupFilesAndRemovesNone() async throws {
        try await withTestApp { app in
            let seed = try await seed(on: app, code: "ATOM202", setupID: "setup_atomic_course_paths")

            let purged = try await app.db.transaction { db in
                try await CoursePurge.deleteRows(
                    of: seed.course, setupsDirectory: app.testSetupsDirectory, on: db)
            }

            #expect(purged.submissionCount == 1)
            #expect(purged.filePaths.contains(seed.submission.zipPath))
            #expect(purged.filePaths.contains(seed.setup.zipPath))
            #expect(try await APICourse.find(seed.courseID, on: app.db) == nil)
            // The helper itself touched no file; the route removes them.
            #expect(fileExists(seed.submission.zipPath))
            #expect(fileExists(seed.setup.zipPath))
        }
    }
}
