// Tests/APITests/LTI/LTIGradeSyncSweepRoutingTests.swift
//
// The rows the AGS grade sweep finishes without a score (docs/lti-1-3.md
// "Grades through AGS"). A row whose assignment is gone is deleted. A Class
// activity row and a row of a course that went back to Valence are dropped:
// the row stays, no longer pending, and the LMS gets no request. A course
// with no line-items URL records the reason and waits for a person. In each
// case a normal row in the same sweep is still sent. The periodic monitor
// runs the same sweep. `LTIGradeSyncTests` covers sending, retries and the
// launch retry.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) final class LTIGradeSyncSweepRoutingTests {
    let app: Application
    let platform: LTITestPlatform
    let lms = LTITestGradeService()
    let keyDirectory: URL

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-lti-routing")
        platform = try await LTITestPlatform.make()
        keyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-lti-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: keyDirectory, withIntermediateDirectories: true)
        app.ltiToolKeyFilePath = keyDirectory.appendingPathComponent(".lti-tool-key").path
        app.ltiServiceClient = await lms.client
    }

    deinit {
        platform.cleanUp()
        try? FileManager.default.removeItem(at: keyDirectory)
    }

    struct Fixture {
        let course: APICourse
        let assignment: APIAssignment
        let setupID: String
        let studentID: UUID
    }

    /// A course on AGS with one 10-point assignment and one launched student
    /// who has a graded submission worth 7 and a pending row from long ago.
    private func fixture(code: String = "CS135") async throws -> Fixture {
        let platformID: UUID
        if let existing = try await APILTIPlatform.query(on: app.db).first() {
            platformID = try existing.requireID()
        } else {
            platformID = try await platform.install(on: app).requireID()
        }
        let course = try await makeTestCourse(on: app, code: code)
        try await LTICourseBinding.bind(course, platformID: platformID, contextID: "context-\(code)", on: app.db)
        course.ltiLineItemsURL = LTITestGradeService.lineItemsURL
        course.ltiGradesEnabled = true
        try await course.save(on: app.db)
        let courseID = try course.requireID()

        let setupID = "setup-\(UUID().uuidString.prefix(8))"
        try await makeTestSetup(
            on: app, id: setupID, courseID: courseID,
            manifest: #"""
                {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"t1.sh","points":10}],"timeLimitSeconds":10,"makefile":null}
                """#)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: "Lab \(code)")
        let student = try await makeTestUser(on: app, username: "student-\(code.lowercased())")
        let studentID = try student.requireID()
        try await APILTIIdentity(platformID: platformID, subject: "subject-\(code)", userID: studentID)
            .save(on: app.db)

        let submissionID = "sub_\(UUID().uuidString.lowercased().prefix(8))"
        try await makeTestSubmission(on: app, id: submissionID, setupID: setupID, userID: studentID)
        try await makeTestResult(
            on: app, submissionID: submissionID, collectionJSON: #"{"earnedPoints":7,"totalPoints":10}"#)
        try await APILTIGradeSync(userID: studentID, testSetupID: setupID, pendingSince: .distantPast)
            .save(on: app.db)
        return Fixture(course: course, assignment: assignment, setupID: setupID, studentID: studentID)
    }

    private func row(userID: UUID, setupID: String) async throws -> APILTIGradeSync? {
        try await APILTIGradeSync.query(on: app.db)
            .filter(\.$userID == userID)
            .filter(\.$testSetupID == setupID)
            .first()
    }

    private func row(_ fixture: Fixture) async throws -> APILTIGradeSync {
        try #require(try await row(userID: fixture.studentID, setupID: fixture.setupID))
    }

    /// The normal row was sent: one score for its student, row finished.
    private func expectSent(_ fixture: Fixture) async throws {
        let sent = try await row(fixture)
        #expect(!sent.pending)
        #expect(sent.syncedAt != nil)
        #expect(sent.error == nil)
    }

    // MARK: - Rows finished without a score

    @Test func aRowWhoseAssignmentIsGoneIsDeleted() async throws {
        try await withApp(app) { app in
            let normal = try await fixture()
            let orphanSetup = "setup-orphan"
            try await makeTestSetup(on: app, id: orphanSetup, courseID: normal.course.requireID())
            try await APILTIGradeSync(userID: normal.studentID, testSetupID: orphanSetup, pendingSince: .distantPast)
                .save(on: app.db)

            #expect(try await app.ltiGradeSyncSweep.run() == 2)

            #expect(try await row(userID: normal.studentID, setupID: orphanSetup) == nil)
            try await expectSent(normal)
            #expect(await lms.scores.map(\.userId) == ["subject-CS135"])
        }
    }

    @Test func aClassActivityRowIsDroppedAndNothingIsSent() async throws {
        try await withApp(app) { app in
            let activity = try await fixture(code: "CS135")
            activity.assignment.assignmentType = .classActivity
            try await activity.assignment.save(on: app.db)
            let normal = try await fixture(code: "CS136")

            #expect(try await app.ltiGradeSyncSweep.run() == 2)

            let dropped = try await row(activity)
            #expect(!dropped.pending)
            #expect(dropped.syncedAt == nil)
            #expect(dropped.error == nil)
            try await expectSent(normal)
            #expect(await lms.scores.map(\.userId) == ["subject-CS136"])
        }
    }

    @Test func aCourseBackOnValenceDropsThePush() async throws {
        try await withApp(app) { app in
            let valence = try await fixture(code: "CS135")
            valence.course.ltiGradesEnabled = false
            try await valence.course.save(on: app.db)
            let normal = try await fixture(code: "CS136")

            #expect(try await app.ltiGradeSyncSweep.run() == 2)

            let dropped = try await row(valence)
            #expect(!dropped.pending)
            #expect(dropped.syncedAt == nil)
            #expect(dropped.error == nil)
            try await expectSent(normal)
            #expect(await lms.scores.map(\.userId) == ["subject-CS136"])
        }
    }

    @Test func aCourseWithNoLineItemsURLWaitsForAPerson() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture()
            fixture.course.ltiLineItemsURL = nil
            try await fixture.course.save(on: app.db)

            #expect(try await app.ltiGradeSyncSweep.run() == 1)

            let failed = try await row(fixture)
            #expect(!failed.pending)
            #expect(failed.failure == .noLineItems)
            #expect(failed.error == LTIGradeSyncSweep.noLineItemsMessage)
            #expect(await lms.requests.isEmpty)
        }
    }

    // MARK: - Monitor

    @Test func theMonitorSendsAPendingRow() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture()

            let monitor = app.ltiGradeSyncMonitor
            #expect(monitor.name == "LTI grade sync")
            monitor.start(application: app)
            var finished = false
            for _ in 0..<200 {
                if try await !row(fixture).pending {
                    finished = true
                    break
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            await monitor.stop()

            #expect(finished)
            try await expectSent(fixture)
            #expect(await lms.scores.first?.scoreGiven == 7)
        }
    }
}

/// The classification of a transport error, and the default AGS client. No
/// database and no network.
@Suite(.timeLimit(.minutes(1))) struct LTIGradeSyncTransportErrorTests {
    private struct TransportError: Error {}

    @Test func aTransportErrorIsRetriedAndStoredAsUnreachable() {
        #expect(LTIGradeSyncSweep.isRetryable(TransportError()))
        #expect(LTIGradeSyncSweep.failureReason(for: TransportError()) == .unreachable)
    }

    @Test func anAppWithNoClientSetBuildsOneOnceAndKeepsIt() async throws {
        try await withTestApp(prefix: "chickadee-lti-client") { app in
            let first = app.ltiServiceClient
            let second = app.ltiServiceClient
            #expect(first === second)
        }
    }
}
