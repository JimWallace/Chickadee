// Tests/APITests/LTI/LTIGradeSyncTests.swift
//
// Grades through AGS end to end (docs/lti-1-3.md slice 4): what queues a
// push, what the sweep sends to a stand-in LMS, how it retries, and that a
// course on AGS never also sends through the Valence sync.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class LTIGradeSyncTests {
    let app: Application
    let platform: LTITestPlatform
    let lms = LTITestGradeService()
    let keyDirectory: URL

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-lti-grades")
        platform = try await LTITestPlatform.make()
        keyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-lti-grades-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: keyDirectory, withIntermediateDirectories: true)
        app.ltiToolKeyFilePath = keyDirectory.appendingPathComponent(".lti-tool-key").path
        app.ltiServiceClient = await lms.client
    }

    deinit {
        platform.cleanUp()
        try? FileManager.default.removeItem(at: keyDirectory)
    }

    struct Fixture {
        let platformID: UUID
        let course: APICourse
        let assignment: APIAssignment
        let setupID: String
        let studentID: UUID
    }

    /// A course on AGS with one 10-point assignment and one student who has
    /// launched from the LMS as `subject-1`.
    private func fixture(usesAGS: Bool = true, launched: Bool = true) async throws -> Fixture {
        let registered = try await platform.install(on: app)
        let platformID = try registered.requireID()
        let course = try await makeTestCourse(on: app, code: "CS135")
        try await LTICourseBinding.bind(course, platformID: platformID, contextID: "context-1", on: app.db)
        course.ltiLineItemsURL = LTITestGradeService.lineItemsURL
        course.ltiGradesEnabled = usesAGS
        try await course.save(on: app.db)
        let courseID = try course.requireID()

        let setupID = "setup-\(UUID().uuidString.prefix(8))"
        try await makeTestSetup(
            on: app, id: setupID, courseID: courseID,
            manifest: #"""
                {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"t1.sh","points":10}],"timeLimitSeconds":10,"makefile":null}
                """#)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: "Lab 1")
        let student = try await makeTestUser(on: app, username: "student1")
        let studentID = try student.requireID()
        if launched {
            try await APILTIIdentity(platformID: platformID, subject: "subject-1", userID: studentID)
                .save(on: app.db)
        }
        return Fixture(
            platformID: platformID, course: course, assignment: assignment, setupID: setupID, studentID: studentID)
    }

    /// A graded submission worth `earned` of 10 points, queued as the result
    /// ingest paths queue it.
    private func submit(_ fixture: Fixture, earned: Int) async throws {
        let submissionID = "sub_\(UUID().uuidString.lowercased().prefix(8))"
        try await makeTestSubmission(on: app, id: submissionID, setupID: fixture.setupID, userID: fixture.studentID)
        try await makeTestResult(
            on: app, submissionID: submissionID, collectionJSON: #"{"earnedPoints":\#(earned),"totalPoints":10}"#)
        try await LTIGradeSyncQueue.queue(submissionID: submissionID, testSetupID: fixture.setupID, on: app.db)
    }

    private func row(_ fixture: Fixture) async throws -> APILTIGradeSync {
        try #require(
            try await APILTIGradeSync.query(on: app.db)
                .filter(\.$userID == fixture.studentID)
                .filter(\.$testSetupID == fixture.setupID)
                .first())
    }

    // MARK: - Sending

    @Test func aGradedSubmissionReachesTheLMS() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture()
            try await submit(fixture, earned: 7)

            try await app.ltiGradeSyncSweep.run(bypassDebounce: true)

            let score = try #require(await lms.scores.first)
            #expect(score.userId == "subject-1")
            #expect(score.scoreGiven == 7)
            #expect(score.scoreMaximum == 10)
            let synced = try await row(fixture)
            #expect(!synced.pending)
            #expect(synced.syncedAt != nil)
            #expect(synced.error == nil)
            let assignment = try #require(try await APIAssignment.find(fixture.assignment.id, on: app.db))
            #expect(assignment.ltiLineItemURL == LTITestGradeService.createdLineItemURL)
        }
    }

    @Test func theLineItemIsFoundOnceAndReused() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture()
            try await submit(fixture, earned: 7)
            try await app.ltiGradeSyncSweep.run(bypassDebounce: true)
            try await submit(fixture, earned: 9)
            try await app.ltiGradeSyncSweep.run(bypassDebounce: true)

            let lineItemRequests = await lms.requests.filter { $0.url.hasPrefix(LTITestGradeService.lineItemsURL) }
            #expect(lineItemRequests.filter { !$0.url.hasSuffix("/scores") }.count == 2)
            #expect(await lms.scores.map(\.scoreGiven) == [7, 9])
        }
    }

    @Test func theSweepWaitsOutTheDebounceWindow() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture()
            try await submit(fixture, earned: 7)

            #expect(try await app.ltiGradeSyncSweep.run() == 0)
            #expect(await lms.requests.isEmpty)
            #expect(try await row(fixture).pending)

            let later = Date().addingTimeInterval(LTIGradeSyncSweep.debounce + 1)
            #expect(try await app.ltiGradeSyncSweep.run(now: later) == 1)
        }
    }

    @Test func aClearedOverrideClearsTheLMSGrade() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture()
            try await applyGradeOverride(
                testSetupID: fixture.setupID, studentUserID: fixture.studentID, percent: 80, note: nil,
                grantedByUserID: nil, on: app.db)
            try await app.ltiGradeSyncSweep.run(bypassDebounce: true)
            #expect(await lms.scores.first?.scoreGiven == 8)

            try await clearGradeOverride(testSetupID: fixture.setupID, studentUserID: fixture.studentID, on: app.db)
            try await app.ltiGradeSyncSweep.run(bypassDebounce: true)

            let cleared = try #require(await lms.scores.last)
            #expect(cleared.scoreGiven == nil)
            #expect(cleared.gradingProgress == "NotReady")
            #expect(try await row(fixture).syncedAt == nil)
        }
    }

    @Test func aStudentWithNoGradeAndNothingSentSendsNothing() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture()
            try await LTIGradeSyncQueue.queue(userIDs: [fixture.studentID], testSetupID: fixture.setupID, on: app.db)

            try await app.ltiGradeSyncSweep.run(bypassDebounce: true)

            #expect(await lms.requests.isEmpty)
            #expect(try await !row(fixture).pending)
        }
    }

    // MARK: - Failures

    @Test func aStudentWhoNeverLaunchedWaitsForTheirFirstLaunch() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture(launched: false)
            try await submit(fixture, earned: 7)
            try await app.ltiGradeSyncSweep.run(bypassDebounce: true)

            let failed = try await row(fixture)
            #expect(!failed.pending)
            #expect(failed.error == LTIGradeSyncSweep.notLaunchedMessage)

            // The student launches: the launch links the identity and queues
            // the push again.
            try await APILTIIdentity(platformID: fixture.platformID, subject: "subject-1", userID: fixture.studentID)
                .save(on: app.db)
            try await LTIRoutes.recordLaunchServices(
                launch: Self.launch(ags: nil), course: fixture.course, userID: fixture.studentID, on: app.db)
            #expect(try await row(fixture).pending)

            try await app.ltiGradeSyncSweep.run(bypassDebounce: true)
            #expect(await lms.scores.first?.scoreGiven == 7)
        }
    }

    @Test func aTransientFailureStaysQueued() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture()
            try await submit(fixture, earned: 7)
            await lms.refuseNextScore(with: .serviceUnavailable)

            try await app.ltiGradeSyncSweep.run(bypassDebounce: true)

            let failed = try await row(fixture)
            #expect(failed.pending)
            #expect(failed.error != nil)
        }
    }

    @Test func aRefusedScoreWaitsForAPerson() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture()
            try await submit(fixture, earned: 7)
            await lms.refuseNextScore(with: .badRequest)

            try await app.ltiGradeSyncSweep.run(bypassDebounce: true)

            let failed = try await row(fixture)
            #expect(!failed.pending)
            #expect(failed.error != nil)
        }
    }

    @Test func aDeletedLineItemIsForgottenAndFoundAgain() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture()
            fixture.assignment.ltiLineItemURL = "https://lms.example.edu/api/lti/courses/7/line_items/1"
            try await fixture.assignment.save(on: app.db)
            try await submit(fixture, earned: 7)
            await lms.refuseNextScore(with: .notFound)

            try await app.ltiGradeSyncSweep.run(bypassDebounce: true)
            #expect(try await row(fixture).pending)
            #expect(try await APIAssignment.find(fixture.assignment.id, on: app.db)?.ltiLineItemURL == nil)

            try await app.ltiGradeSyncSweep.run(bypassDebounce: true)
            #expect(
                try await APIAssignment.find(fixture.assignment.id, on: app.db)?.ltiLineItemURL
                    == LTITestGradeService.createdLineItemURL)
            #expect(try await !row(fixture).pending)
        }
    }

    @Test func theLaunchRetryKeysOnTheReasonCodeNotTheSentence() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture(launched: false)
            try await submit(fixture, earned: 7)
            try await app.ltiGradeSyncSweep.run(bypassDebounce: true)
            let courseID = try fixture.course.requireID()

            let failed = try await row(fixture)
            #expect(failed.failure == .notLaunched)
            // A reworded sentence must not change what the launch retries.
            failed.error = "Reworded."
            try await failed.save(on: app.db)
            try await LTIGradeSyncQueue.retryFailed(userID: fixture.studentID, courseID: courseID, on: app.db)
            let retried = try await row(fixture)
            #expect(retried.pending)
            #expect(retried.failure == nil)

            // Any other reason waits for a person, whatever its sentence says.
            retried.pending = false
            retried.failure = .noLineItems
            retried.error = LTIGradeSyncSweep.notLaunchedMessage
            try await retried.save(on: app.db)
            try await LTIGradeSyncQueue.retryFailed(userID: fixture.studentID, courseID: courseID, on: app.db)
            #expect(try await !row(fixture).pending)
        }
    }

    @Test func aFailureShowsOneShortSentence() async throws {
        // A class suite builds an app per test, which must be shut down.
        try await withApp(app) { _ in
            struct TransportError: Error {}
            #expect(LTIGradeSyncSweep.reason(for: TransportError()) == LTIGradeSyncSweep.unreachableMessage)
            #expect(
                LTIGradeSyncSweep.reason(for: BrightSpaceSyncError.missingPoints) == LTIGradeSyncSweep.noGradeMessage)
            #expect(
                LTIGradeSyncSweep.reason(for: LTIServiceError.lineItemGone) == LTIServiceError.lineItemGone.description)

            // Every reason the page can show stays short: the page lists them in
            // a table column, so none may grow into a paragraph.
            let reasons =
                [
                    LTIGradeSyncSweep.notLaunchedMessage, LTIGradeSyncSweep.noLineItemsMessage,
                    LTIGradeSyncSweep.noTotalMessage, LTIGradeSyncSweep.noGradeMessage,
                    LTIGradeSyncSweep.unreachableMessage, LTIServiceError.lineItemGone.description,
                ]
                + [LTIServiceError.Step.token, .findLineItem, .createLineItem, .postScore].flatMap { step in
                    [
                        LTIServiceError.rejected(step, status: 500).description,
                        LTIServiceError.unreadableResponse(step).description,
                    ]
                }
            for reason in reasons {
                #expect(reason.split(separator: " ").count <= 15, "\(reason)")
            }
        }
    }

    // MARK: - One transport per course

    @Test func aValenceCourseQueuesNothing() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture(usesAGS: false)
            try await submit(fixture, earned: 7)

            #expect(try await APILTIGradeSync.query(on: app.db).count() == 0)
        }
    }

    @Test func theValenceSweepLeavesAnAGSCourseAlone() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture()
            fixture.course.brightspaceOrgUnitID = "ou-1"
            try await fixture.course.save(on: app.db)
            fixture.assignment.brightspaceGradeObjectID = "go-1"
            try await fixture.assignment.save(on: app.db)
            let submissionID = "sub_valence"
            try await makeTestSubmission(on: app, id: submissionID, setupID: fixture.setupID, userID: fixture.studentID)
            let result = try await makeTestResult(
                on: app, submissionID: submissionID, collectionJSON: #"{"earnedPoints":7,"totalPoints":10}"#)
            result.brightspaceSyncPending = true
            result.brightspacePendingSince = .distantPast
            try await result.save(on: app.db)

            // With no Valence identity, a Valence course would stay pending
            // for a later sweep. An AGS course is cleared as a no-op instead.
            try await sweepBrightSpaceGradeSync(
                on: app.db, debounceSecs: 0, resolveClient: { _ in nil }, logger: app.logger, application: app)

            let swept = try #require(try await APIResult.find(result.id, on: app.db))
            #expect(swept.brightspaceSyncPending == false)
            #expect(swept.brightspaceSyncError == nil)
        }
    }

    // MARK: - Launch

    @Test func aLaunchRecordsTheLineItemsURL() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture()
            fixture.course.ltiLineItemsURL = nil
            try await fixture.course.save(on: app.db)
            let url = "https://lms.example.edu/api/lti/courses/7/line_items"

            try await LTIRoutes.recordLaunchServices(
                launch: Self.launch(ags: Self.endpoint(url)), course: fixture.course,
                userID: fixture.studentID, on: app.db)

            #expect(try await APICourse.find(fixture.course.id, on: app.db)?.ltiLineItemsURL == url)
        }
    }

    @Test func aLaunchIgnoresAnInsecureLineItemsURL() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture()
            fixture.course.ltiLineItemsURL = nil
            try await fixture.course.save(on: app.db)

            try await LTIRoutes.recordLaunchServices(
                launch: Self.launch(ags: Self.endpoint("http://lms.example.edu/items")), course: fixture.course,
                userID: fixture.studentID, on: app.db)

            #expect(try await APICourse.find(fixture.course.id, on: app.db)?.ltiLineItemsURL == nil)
        }
    }

    private static func endpoint(_ url: String) -> LTIAGSEndpoint {
        LTIAGSEndpoint(scope: LTIServiceClient.agsScopes, lineItems: url, lineItem: nil)
    }

    private static func launch(ags: LTIAGSEndpoint?) -> LTIValidatedLaunch {
        LTIValidatedLaunch(
            messageType: .resourceLink, subject: "subject-1", nonce: "nonce",
            deploymentID: LTITestPlatform.deploymentID,
            courseRole: .student, context: LTILaunchClaims.Context(id: "context-1", label: nil, title: nil),
            resourceLink: LTILaunchClaims.ResourceLink(id: "link-1", title: nil), name: nil, email: nil,
            custom: [:], agsEndpoint: ags)
    }
}
