// Tests/APITests/LTI/LTIGradeSyncTests.swift
//
// Grades through AGS end to end (docs/lti-1-3.md slice 4): what queues a
// push, what the sweep sends to a stand-in LMS, how it retries, and that a
// course on AGS never also sends through the Valence sync.
//
// `LTIGradeSyncQueueUpsertTests`: the AGS push queue writes each student's
// row in one upsert per chunk. A row that is already waiting keeps its start
// time, so a stream of submissions cannot hold the push back forever; a row
// that finished, or failed, waits again from now with its error cleared.
//
// `LTIGradeSyncSweepRoutingTests`: the rows the AGS grade sweep finishes
// without a score (docs/lti-1-3.md "Grades through AGS"). A row whose
// assignment is gone is deleted. A Class activity row and a row of a course
// that went back to Valence are dropped: the row stays, no longer pending,
// and the LMS gets no request. A course with no line-items URL records the
// reason and waits for a person. In each case a normal row in the same sweep
// is still sent. The periodic monitor runs the same sweep.

import ChickadeeTestSupport
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

/// The failure reasons and their classification are pure, so these tests
/// need no app.
@Suite struct LTIGradeSyncReasonTests {
    @Test func aFailureShowsOneShortSentence() {
        struct TransportError: Error {}
        #expect(LTIGradeSyncSweep.reason(for: TransportError()) == LTIGradeSyncSweep.unreachableMessage)
        #expect(
            LTIGradeSyncSweep.reason(for: GradeSelectionError.missingPoints) == LTIGradeSyncSweep.noGradeMessage)
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

    @Test func aGradeSelectionFailureIsTerminalAndStoredAsNoGrade() {
        // Grade selection reports in its own type, so the AGS sweep
        // classifies it without knowing the Valence error taxonomy.
        #expect(!LTIGradeSyncSweep.isRetryable(GradeSelectionError.missingPoints))
        #expect(LTIGradeSyncSweep.failureReason(for: GradeSelectionError.missingPoints) == .noGrade)
    }
}

// MARK: - The queue upsert

@Suite(.serialized, .timeLimit(.minutes(5)))
struct LTIGradeSyncQueueUpsertTests {

    private func rows(_ setupID: String, on app: Application) async throws -> [UUID: APILTIGradeSync] {
        let all = try await APILTIGradeSync.query(on: app.db).filter(\.$testSetupID == setupID).all()
        return Dictionary(all.map { ($0.userID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    @Test func aWaitingRowKeepsItsStartAndADoneRowStartsAgain() async throws {
        try await withTestApp(prefix: "chickadee-lti-upsert") { app in
            let course = try await makeTestCourse(on: app, code: "AGS101")
            course.ltiGradesEnabled = true
            course.ltiPlatformID = UUID()
            try await course.save(on: app.db)
            let courseID = try course.requireID()
            let setupID = "setup_lti_upsert"
            try await makeTestSetup(on: app, id: setupID, courseID: courseID)
            try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
            let first = try await makeTestStudent(on: app, username: "lti_upsert_a").requireID()
            let second = try await makeTestStudent(on: app, username: "lti_upsert_b").requireID()

            let start = Date(timeIntervalSince1970: 1_000_000)
            // A repeated user in one call is one row.
            try await LTIGradeSyncQueue.queue(
                userIDs: [first, second, first], testSetupID: setupID, on: app.db, now: start)
            var queued = try await rows(setupID, on: app)
            #expect(queued.count == 2)
            #expect(queued[first]?.pending == true)
            #expect(queued[first]?.pendingSince == start)

            // The first student's push finishes, with an error to clear.
            let done = try #require(queued[first])
            done.pending = false
            done.error = "LMS refused"
            done.failure = .notLaunched
            try await done.save(on: app.db)

            let later = start.addingTimeInterval(600)
            try await LTIGradeSyncQueue.queue(userIDs: [first, second], testSetupID: setupID, on: app.db, now: later)
            queued = try await rows(setupID, on: app)
            #expect(queued.count == 2)
            // Done, so it waits again from now, with no error.
            #expect(queued[first]?.pending == true)
            #expect(queued[first]?.pendingSince == later)
            #expect(queued[first]?.error == nil)
            #expect(queued[first]?.failureReason == nil)
            // Still waiting, so it keeps its start.
            #expect(queued[second]?.pending == true)
            #expect(queued[second]?.pendingSince == start)
        }
    }
}

// MARK: - Rows the sweep finishes without a score

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
            await monitor.sweepOnce(application: app)
            let finished = try await !row(fixture).pending

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
