// Tests/APITests/Grading/SubmissionIntakeTests.swift
//
// `SubmissionIntake` is the one place a student submission is stored and its
// effects run (#2768). These tests call it directly and pin each effect:
// the file, the row, the attempt number, Pathfinder, and the diagnostics that
// a queued job records. `SubmissionIntakeDoorTests` checks that every door
// reaches it.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3)))
struct SubmissionIntakeTests {

    /// A worker-graded setup in the shared test course, and a user in that
    /// course with `role`.
    private func fixture(
        _ app: Application, prefix: String, role: CourseRole = .student
    ) async throws -> (setup: APITestSetup, user: APIUser) {
        let courseID = try await app.testCourseID()
        let setup = try await makeTestSetup(
            on: app, id: "\(prefix)_setup", courseID: courseID,
            manifest: TestManifests.workerOnePythonSuite, withNotebook: false)
        let username = "\(prefix)_user"
        _ = try await loginAsStudent(username, on: app)
        try await enrollInTestCourse(username: username, role: role, on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        return (setup, user)
    }

    private func hasDiagnostics(_ app: Application, _ submissionID: String) async throws -> Bool {
        let diagnostics = try await APISubmissionDiagnostics.find(submissionID, on: app.db)
        let metric = try await JobExecutionMetric.query(on: app.db)
            .filter(\.$submissionID == submissionID).first()
        return diagnostics != nil && metric != nil
    }

    private func pathfinderHolder(_ app: Application, _ setupID: String) async throws -> APIClassAchievement? {
        try await APIClassAchievement.query(on: app.db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$achievementID == "pathfinder")
            .first()
    }

    @Test func aPendingSubmissionIsStoredNumberedAndRecorded() async throws {
        try await withTestApp(prefix: "chickadee-intake") { app in
            let (setup, user) = try await fixture(app, prefix: "intake_pending")
            let req = makeTestRequest(on: app)
            let bytes = Data("print(1)\n".utf8)

            let first = try await SubmissionIntake(req: req, submissionID: "sub_intake_p1").accept(
                setup: setup, owner: user,
                artifact: .bytes(bytes, fileExtension: "py"),
                filename: "main.py", status: .pending)
            let second = try await SubmissionIntake(req: req, submissionID: "sub_intake_p2").accept(
                setup: setup, owner: user,
                artifact: .bytes(bytes, fileExtension: "py"),
                filename: "main.py", status: .pending)

            let stored = try #require(try await APISubmission.find("sub_intake_p1", on: app.db))
            #expect(stored.zipPath == app.submissionsDirectory + "sub_intake_p1.py")
            #expect(try Data(contentsOf: URL(fileURLWithPath: stored.zipPath)) == bytes)
            #expect(stored.userID == user.id)
            #expect(stored.filename == "main.py")
            #expect(stored.status == SubmissionStatus.pending.rawValue)
            #expect(first.attemptNumber == 1)
            #expect(second.attemptNumber == 2)
            #expect(try await hasDiagnostics(app, "sub_intake_p1"))
            #expect(try await hasDiagnostics(app, "sub_intake_p2"))
            // First to submit wins, and a later submission does not move it.
            #expect(try await pathfinderHolder(app, try setup.requireID())?.submissionID == "sub_intake_p1")
        }
    }

    /// A browser result is stored complete. No runner grades it, so it
    /// records no enqueue. Its door awards Pathfinder after it stores the
    /// result, so the intake awards nothing.
    @Test func aCompleteSubmissionRecordsNoEnqueue() async throws {
        try await withTestApp(prefix: "chickadee-intake") { app in
            let (setup, user) = try await fixture(app, prefix: "intake_complete")
            try await SubmissionIntake(req: makeTestRequest(on: app), submissionID: "sub_intake_c1").accept(
                setup: setup, owner: user,
                artifact: .bytes(Data("{}".utf8), fileExtension: "ipynb"),
                filename: "sub_intake_c1.ipynb", status: .complete)

            let stored = try #require(try await APISubmission.find("sub_intake_c1", on: app.db))
            #expect(stored.status == SubmissionStatus.complete.rawValue)
            #expect(try await !hasDiagnostics(app, "sub_intake_c1"))
            #expect(try await pathfinderHolder(app, try setup.requireID()) == nil)
        }
    }

    /// The REST doors save no owner: the attempt number is counted per setup,
    /// and nobody is awarded Pathfinder. The job is still recorded.
    @Test func aSubmissionWithNoOwnerIsCountedPerSetupAndAwardsNothing() async throws {
        try await withTestApp(prefix: "chickadee-intake") { app in
            let (setup, user) = try await fixture(app, prefix: "intake_noowner")
            let req = makeTestRequest(on: app)
            try await SubmissionIntake(req: req, submissionID: "sub_intake_n0").accept(
                setup: setup, owner: user,
                artifact: .bytes(Data("a".utf8), fileExtension: "py"),
                filename: nil, status: .pending)
            try await APIClassAchievement.query(on: app.db).delete()

            let anonymous = try await SubmissionIntake(req: req, submissionID: "sub_intake_n1").accept(
                setup: setup, owner: nil,
                artifact: .bytes(Data("b".utf8), fileExtension: "zip"),
                filename: nil, status: .pending)

            #expect(anonymous.userID == nil)
            #expect(anonymous.attemptNumber == 2, "counted across every student row of the setup")
            #expect(try await hasDiagnostics(app, "sub_intake_n1"))
            #expect(try await pathfinderHolder(app, try setup.requireID()) == nil)
        }
    }

    /// Course staff testing an assignment must not lock in the immutable badge.
    @Test func staffDoNotTakePathfinder() async throws {
        try await withTestApp(prefix: "chickadee-intake") { app in
            let (setup, user) = try await fixture(app, prefix: "intake_staff", role: .ta)
            try await SubmissionIntake(req: makeTestRequest(on: app), submissionID: "sub_intake_s1").accept(
                setup: setup, owner: user,
                artifact: .bytes(Data("a".utf8), fileExtension: "py"),
                filename: nil, status: .pending)
            #expect(try await pathfinderHolder(app, try setup.requireID()) == nil)
        }
    }

    /// A door that wrote its own file (GitHub) hands over the path. The intake
    /// does not write it again, and `prepare` sets columns before the save.
    @Test func aStoredArtifactIsKeptAndPrepareRunsBeforeTheSave() async throws {
        try await withTestApp(prefix: "chickadee-intake") { app in
            let (setup, user) = try await fixture(app, prefix: "intake_stored")
            let intake = SubmissionIntake(req: makeTestRequest(on: app), submissionID: "sub_intake_g1")
            let path = intake.path(fileExtension: "zip")
            #expect(path == app.submissionsDirectory + "sub_intake_g1.zip")
            let bytes = Data("written by the door".utf8)
            try bytes.write(to: URL(fileURLWithPath: path))

            try await intake.accept(
                setup: setup, owner: user, artifact: .stored(path: path),
                filename: nil, status: .pending
            ) { submission in
                submission.sourceKind = SubmissionSource.github.rawValue
                submission.sourceCommit = "abc"
            }

            let stored = try #require(try await APISubmission.find("sub_intake_g1", on: app.db))
            #expect(stored.zipPath == path)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
            #expect(stored.sourceKind == SubmissionSource.github.rawValue)
            #expect(stored.sourceCommit == "abc")
            #expect(try await hasDiagnostics(app, "sub_intake_g1"))
        }
    }

    /// With no instructor notebook to read, the student's notebook is merged
    /// with itself, as the browser doors always did.
    @Test func aMissingInstructorNotebookMergesTheStudentNotebookWithItself() async throws {
        try await withTestApp(prefix: "chickadee-intake") { app in
            let (setup, _) = try await fixture(app, prefix: "intake_merge")
            let student = Data(
                #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","source":["x = 1"],"metadata":{},"outputs":[]}]}"#
                    .utf8)
            let merged = try await SubmissionIntake(req: makeTestRequest(on: app))
                .mergedWithInstructorNotebook(student, setup: setup)
            #expect(merged == mergeNotebook(student: student, instructor: student))
        }
    }
}
