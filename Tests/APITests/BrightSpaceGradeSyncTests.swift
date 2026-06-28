// Tests/APITests/BrightSpaceGradeSyncTests.swift
//
// Exercises the BrightSpace grade-sync sweep logic (best-grade selection,
// debounce filtering, D2L user-ID caching, skip/error paths) against an
// in-memory `BrightSpaceGrading` fake — no live D2L endpoint required.
// The seam these tests rely on is the `BrightSpaceGrading` protocol that
// `BrightSpaceAPIClient` conforms to.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

// MARK: - Fake grading client

/// In-memory `BrightSpaceGrading` conformer. Records grade pushes and serves
/// canned user-ID lookups so the sweep can be driven without HTTP.
private actor FakeBrightSpaceGrading: BrightSpaceGrading {
    struct RecordedPush: Sendable, Equatable {
        let orgUnitID: String
        let gradeObjectID: String
        let bsUserID: String
        let earnedPoints: Double
    }

    private let userIDsByOrgDefinedId: [String: String]
    private let classlist: [BrightSpaceClasslistEntry]
    private let lookupError: (any Error)?
    private let pushError: (any Error)?
    /// Grade-item metadata returned by `fetchGradeObject`. Default `nil` mimics
    /// "item not found", which the sweep treats as "no scaling, no type check"
    /// — so the pushed value equals Chickadee's raw points unless a test opts
    /// into a specific grade object (to exercise scaling / type refusal).
    private let gradeObject: BrightSpaceGradeObject?
    private let clearError: (any Error)?
    private(set) var pushes: [RecordedPush] = []
    private(set) var clears: [String] = []  // bsUserIDs whose grade was cleared
    private(set) var lookupCount = 0

    init(
        userIDsByOrgDefinedId: [String: String] = [:],
        classlist: [BrightSpaceClasslistEntry] = [],
        lookupError: (any Error)? = nil,
        pushError: (any Error)? = nil,
        gradeObject: BrightSpaceGradeObject? = nil,
        clearError: (any Error)? = nil
    ) {
        self.userIDsByOrgDefinedId = userIDsByOrgDefinedId
        self.classlist = classlist
        self.lookupError = lookupError
        self.pushError = pushError
        self.gradeObject = gradeObject
        self.clearError = clearError
    }

    func lookupUserID(orgDefinedId: String, on application: Application) async throws -> String? {
        lookupCount += 1
        if let lookupError { throw lookupError }
        return userIDsByOrgDefinedId[orgDefinedId]
    }

    func fetchClasslist(
        orgUnitID: String, on application: Application
    ) async throws -> [BrightSpaceClasslistEntry] {
        classlist
    }

    func fetchGradeObject(
        orgUnitID: String, gradeObjectID: String, on application: Application
    ) async throws -> BrightSpaceGradeObject? {
        gradeObject
    }

    func clearGrade(
        orgUnitID: String, gradeObjectID: String, bsUserID: String, on application: Application
    ) async throws {
        if let clearError { throw clearError }
        clears.append(bsUserID)
    }

    func pushGrade(
        orgUnitID: String,
        gradeObjectID: String,
        bsUserID: String,
        earnedPoints: Double,
        on application: Application
    ) async throws {
        if let pushError { throw pushError }
        pushes.append(
            RecordedPush(
                orgUnitID: orgUnitID,
                gradeObjectID: gradeObjectID,
                bsUserID: bsUserID,
                earnedPoints: earnedPoints
            )
        )
    }
}

// MARK: - Suite

@Suite(.serialized) final class BrightSpaceGradeSyncTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-brightspace")
    }

    // MARK: Fixture helpers

    private func pointsJSON(earned: Int, total: Int) -> String {
        #"{"earnedPoints":\#(earned),"totalPoints":\#(total)}"#
    }

    private func passCountJSON(_ count: Int) -> String {
        #"{"passCount":\#(count)}"#
    }

    /// Builds a fully-wired course/setup/assignment/user/submission graph that
    /// the sweep will treat as eligible for grade sync.
    private func makeConfiguredScenario(
        orgUnitID: String = "ou-123",
        gradeObjectID: String = "go-456",
        studentID: String? = "stu-001",
        brightspaceUserID: String? = nil,
        submissionKind: String = APISubmission.Kind.student
    ) async throws -> (setupID: String, submissionID: String, userID: UUID) {
        let course = try await makeTestCourse(on: app, code: "BS101")
        course.brightspaceOrgUnitID = orgUnitID
        try await course.save(on: app.db)
        let courseID = try course.requireID()

        let setupID = "ts_\(UUID().uuidString.lowercased().prefix(8))"
        _ = try await makeTestSetup(on: app, id: setupID, courseID: courseID)

        let assignment = try await makeTestAssignment(
            on: app,
            testSetupID: setupID,
            courseID: courseID,
            title: "BrightSpace Lab"
        )
        assignment.brightspaceGradeObjectID = gradeObjectID
        try await assignment.save(on: app.db)

        let user = try await makeTestUser(on: app, username: "bs_\(UUID().uuidString.lowercased().prefix(6))")
        user.studentID = studentID
        user.brightspaceUserID = brightspaceUserID
        try await user.save(on: app.db)
        let userID = try user.requireID()

        let submissionID = "sub_\(UUID().uuidString.lowercased().prefix(8))"
        _ = try await makeTestSubmission(
            on: app,
            id: submissionID,
            setupID: setupID,
            userID: userID,
            kind: submissionKind
        )

        return (setupID, submissionID, userID)
    }

    @discardableResult
    private func makePendingResult(
        submissionID: String,
        json: String,
        source: String = "worker",
        pendingSince: Date
    ) async throws -> APIResult {
        let result = try await makeTestResult(
            on: app,
            submissionID: submissionID,
            collectionJSON: json,
            source: source
        )
        result.brightspaceSyncPending = true
        result.brightspacePendingSince = pendingSince
        try await result.save(on: app.db)
        return result
    }

    /// A manifest whose suite items sum to `total` points, so
    /// `suiteTotalPoints` (the override → points denominator) is non-zero.
    private func pointsManifest(total: Int) -> String {
        #"""
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"t1.sh","points":\#(total)}],"timeLimitSeconds":10,"makefile":null}
        """#
    }

    /// Builds a configured course/setup/assignment/user graph with NO
    /// submission — the "pending student manually registered for grade-sync
    /// testing" case. The setup's manifest sums to `suiteTotal` points so an
    /// override percent converts to points.
    private func makeOverrideOnlyScenario(
        suiteTotal: Int = 10,
        orgUnitID: String = "ou-ovr",
        gradeObjectID: String = "go-ovr",
        studentID: String? = "stu-ovr"
    ) async throws -> (setupID: String, userID: UUID) {
        let course = try await makeTestCourse(on: app, code: "BSOVR")
        course.brightspaceOrgUnitID = orgUnitID
        try await course.save(on: app.db)
        let courseID = try course.requireID()

        let setupID = "ts_\(UUID().uuidString.lowercased().prefix(8))"
        _ = try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: pointsManifest(total: suiteTotal))

        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: "Override-only Lab")
        assignment.brightspaceGradeObjectID = gradeObjectID
        try await assignment.save(on: app.db)

        let user = try await makeTestUser(on: app, username: "ovr_\(UUID().uuidString.lowercased().prefix(6))")
        user.studentID = studentID
        try await user.save(on: app.db)
        return (setupID, try user.requireID())
    }

    /// Drives the sweep with a constant per-course identity (the fake), so the
    /// existing tests exercise grade selection / debounce / caching unchanged.
    private func sweep(client: any BrightSpaceGrading, debounceSecs: TimeInterval = 90) async throws -> Int {
        try await sweepBrightSpaceGradeSync(
            on: app.db,
            debounceSecs: debounceSecs,
            resolveClient: { _ in client },
            logger: app.logger,
            application: app
        )
    }

    /// Drives the sweep with a resolver that returns no identity for any course,
    /// modelling a course whose designated instructor hasn't connected yet.
    private func sweepWithNoIdentity(debounceSecs: TimeInterval = 90) async throws -> Int {
        try await sweepBrightSpaceGradeSync(
            on: app.db,
            debounceSecs: debounceSecs,
            resolveClient: { _ in nil },
            logger: app.logger,
            application: app
        )
    }

    // MARK: Tests

    @Test func happyPathPushesGradeAndCachesUserID() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeConfiguredScenario(studentID: "stu-001")
            try await makePendingResult(
                submissionID: scenario.submissionID,
                json: pointsJSON(earned: 8, total: 10),
                pendingSince: Date().addingTimeInterval(-3600)
            )
            let fake = FakeBrightSpaceGrading(userIDsByOrgDefinedId: ["stu-001": "d2l-999"])

            let processed = try await sweep(client: fake)

            #expect(processed == 1)
            let pushes = await fake.pushes
            #expect(pushes.count == 1)
            #expect(pushes.first?.orgUnitID == "ou-123")
            #expect(pushes.first?.gradeObjectID == "go-456")
            #expect(pushes.first?.bsUserID == "d2l-999")
            #expect(pushes.first?.earnedPoints == 8)

            let result = try #require(try await APIResult.query(on: app.db).first())
            #expect(result.brightspaceSyncPending == false)
            #expect(result.brightspaceSyncedAt != nil)
            #expect(result.brightspaceSyncError == nil)

            // D2L user ID resolved once and cached on the user.
            let user = try await APIUser.find(scenario.userID, on: app.db)
            #expect(user?.brightspaceUserID == "d2l-999")
            let lookupCount = await fake.lookupCount
            #expect(lookupCount == 1)
        }
    }

    @Test func resolvesByUsernameFromClasslistWhenNoStudentID() async throws {
        try await withApp(app) { _ in
            // SSO-typical: the student has a username but no student number.
            let scenario = try await makeConfiguredScenario(studentID: nil)
            try await makePendingResult(
                submissionID: scenario.submissionID,
                json: pointsJSON(earned: 7, total: 10),
                pendingSince: Date().addingTimeInterval(-3600)
            )
            let user = try #require(try await APIUser.find(scenario.userID, on: app.db))
            // Classlist carries the username (UPPER-cased to prove case-insensitive
            // matching) + the D2L UserId; no OrgDefinedId, empty lookup table.
            let fake = FakeBrightSpaceGrading(
                classlist: [
                    BrightSpaceClasslistEntry(
                        orgDefinedID: nil, username: user.username.uppercased(), userID: "d2l-777")
                ])

            let processed = try await sweep(client: fake)

            #expect(processed == 1)
            let pushes = await fake.pushes
            #expect(pushes.first?.bsUserID == "d2l-777")
            // Resolved by username via the classlist — the org-level lookup never ran.
            let lookupCount = await fake.lookupCount
            #expect(lookupCount == 0)
            let reloaded = try await APIUser.find(scenario.userID, on: app.db)
            #expect(reloaded?.brightspaceUserID == "d2l-777")
        }
    }

    @Test func debounceWindowSkipsRecentResults() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeConfiguredScenario()
            try await makePendingResult(
                submissionID: scenario.submissionID,
                json: pointsJSON(earned: 5, total: 10),
                pendingSince: Date()  // inside the 90s debounce window
            )
            let fake = FakeBrightSpaceGrading(userIDsByOrgDefinedId: ["stu-001": "d2l-1"])

            let processed = try await sweep(client: fake)

            #expect(processed == 0)
            let pushes = await fake.pushes
            #expect(pushes.isEmpty)
            let result = try #require(try await APIResult.query(on: app.db).first())
            #expect(result.brightspaceSyncPending == true)  // still waiting
        }
    }

    @Test func bestGradePrefersWorkerResultsOverBrowser() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeConfiguredScenario(brightspaceUserID: "d2l-cached")
            // One pending worker result triggers the sweep; the best grade is
            // computed across every result for this student's submissions.
            try await makePendingResult(
                submissionID: scenario.submissionID,
                json: passCountJSON(3),
                source: "worker",
                pendingSince: Date().addingTimeInterval(-3600)
            )
            try await makeTestResult(
                on: app,
                submissionID: scenario.submissionID,
                collectionJSON: passCountJSON(7),
                source: "worker"
            )
            // Browser result with a higher score must be ignored when worker
            // results exist.
            try await makeTestResult(
                on: app,
                submissionID: scenario.submissionID,
                collectionJSON: passCountJSON(100),
                source: "browser"
            )
            let fake = FakeBrightSpaceGrading()

            let processed = try await sweep(client: fake)

            #expect(processed == 1)
            let pushes = await fake.pushes
            #expect(pushes.count == 1)
            #expect(pushes.first?.earnedPoints == 7)
            #expect(pushes.first?.bsUserID == "d2l-cached")
            // Cached D2L ID means no lookup call.
            let lookupCount = await fake.lookupCount
            #expect(lookupCount == 0)
        }
    }

    @Test func missingPointsRecordsErrorAndClearsFlag() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeConfiguredScenario(brightspaceUserID: "d2l-1")
            try await makePendingResult(
                submissionID: scenario.submissionID,
                json: #"{"outcomes":[]}"#,
                pendingSince: Date().addingTimeInterval(-3600)
            )
            let fake = FakeBrightSpaceGrading()

            let processed = try await sweep(client: fake)

            #expect(processed == 0)  // threw → not counted as a successful push
            let pushes = await fake.pushes
            #expect(pushes.isEmpty)
            let result = try #require(try await APIResult.query(on: app.db).first())
            #expect(result.brightspaceSyncPending == false)
            #expect(result.brightspaceSyncError != nil)
        }
    }

    @Test func noBrightSpaceAccountRecordsSkipMessage() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeConfiguredScenario(studentID: "stu-unknown")
            try await makePendingResult(
                submissionID: scenario.submissionID,
                json: pointsJSON(earned: 9, total: 10),
                pendingSince: Date().addingTimeInterval(-3600)
            )
            // Fake has no D2L user for this orgDefinedId.
            let fake = FakeBrightSpaceGrading(userIDsByOrgDefinedId: [:])

            let processed = try await sweep(client: fake)

            #expect(processed == 1)  // skip is a normal return, not a failure
            let pushes = await fake.pushes
            #expect(pushes.isEmpty)
            let result = try #require(try await APIResult.query(on: app.db).first())
            #expect(result.brightspaceSyncPending == false)
            #expect(result.brightspaceSyncError?.contains("no BrightSpace account") == true)
        }
    }

    @Test func validationSubmissionIsSkipped() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeConfiguredScenario(submissionKind: APISubmission.Kind.validation)
            try await makePendingResult(
                submissionID: scenario.submissionID,
                json: pointsJSON(earned: 10, total: 10),
                pendingSince: Date().addingTimeInterval(-3600)
            )
            let fake = FakeBrightSpaceGrading(userIDsByOrgDefinedId: ["stu-001": "d2l-1"])

            let processed = try await sweep(client: fake)

            #expect(processed == 1)
            let pushes = await fake.pushes
            #expect(pushes.isEmpty)  // validation runs never sync grades
            let result = try #require(try await APIResult.query(on: app.db).first())
            #expect(result.brightspaceSyncPending == false)
        }
    }

    @Test func noConnectedIdentityDefersAndLeavesPending() async throws {
        // A course whose designated instructor hasn't connected (resolver → nil)
        // must NOT clear the flag — the grade should push once an identity
        // connects, so the row stays pending for a later sweep.
        try await withApp(app) { _ in
            let scenario = try await makeConfiguredScenario(brightspaceUserID: "d2l-1")
            try await makePendingResult(
                submissionID: scenario.submissionID,
                json: pointsJSON(earned: 6, total: 10),
                pendingSince: Date().addingTimeInterval(-3600)
            )

            let processed = try await sweepWithNoIdentity()

            #expect(processed == 0)
            let result = try #require(try await APIResult.query(on: app.db).first())
            #expect(result.brightspaceSyncPending == true)
            #expect(result.brightspaceSyncError == nil)
        }
    }

    @Test func overrideOnStudentWithNoSubmissionsPushesGrade() async throws {
        // A manually-registered pending student (no submissions) graded only by
        // an instructor override must still push: the override row carries the
        // pending flag, and the push converts percent → points against the
        // suite total.
        try await withApp(app) { _ in
            let scenario = try await makeOverrideOnlyScenario(suiteTotal: 10, studentID: "stu-ovr")
            try await applyGradeOverride(
                testSetupID: scenario.setupID,
                studentUserID: scenario.userID,
                percent: 50,
                note: "manual",
                grantedByUserID: nil,
                on: app.db
            )
            // applyGradeOverride flags the override row pending from "now";
            // backdate past the debounce window so the sweep picks it up.
            let override = try #require(try await APIGradeOverride.query(on: app.db).first())
            #expect(override.brightspaceSyncPending == true)
            override.brightspacePendingSince = Date().addingTimeInterval(-3600)
            try await override.save(on: app.db)

            let fake = FakeBrightSpaceGrading(userIDsByOrgDefinedId: ["stu-ovr": "d2l-ovr"])
            let processed = try await sweep(client: fake)

            #expect(processed == 1)
            let pushes = await fake.pushes
            #expect(pushes.count == 1)
            #expect(pushes.first?.bsUserID == "d2l-ovr")
            #expect(pushes.first?.earnedPoints == 5)  // 50% of 10
            // Override row marked synced, flag cleared.
            let reloaded = try #require(try await APIGradeOverride.query(on: app.db).first())
            #expect(reloaded.brightspaceSyncPending == false)
            #expect(reloaded.brightspaceSyncedAt != nil)
            #expect(reloaded.brightspaceSyncError == nil)
        }
    }

    @Test func clearingOverrideNeverSyncedQueuesNoRemoval() async throws {
        // Clearing an override on a no-submission student that Chickadee never
        // pushed (no success in the sync log) queues no removal — Chickadee only
        // ever touches grades it pushed.
        try await withApp(app) { _ in
            let scenario = try await makeOverrideOnlyScenario(studentID: "stu-ovr")
            try await applyGradeOverride(
                testSetupID: scenario.setupID, studentUserID: scenario.userID,
                percent: 75, note: nil, grantedByUserID: nil, on: app.db)
            _ = try await clearGradeOverride(
                testSetupID: scenario.setupID, studentUserID: scenario.userID, on: app.db)

            #expect(try await APIGradeOverride.query(on: app.db).count() == 0)
            #expect(try await APIBrightSpaceGradeClear.query(on: app.db).count() == 0)

            let fake = FakeBrightSpaceGrading(userIDsByOrgDefinedId: ["stu-ovr": "d2l-ovr"])
            let processed = try await sweep(client: fake)

            #expect(processed == 0)
            #expect(await fake.pushes.isEmpty)
            #expect(await fake.clears.isEmpty)
        }
    }

    @Test func clearingOverrideAfterSyncRemovesGradeInLearn() async throws {
        // Full bidirectional path: push a grade for a no-submission student, then
        // clear the override — the next sweep removes the grade in LEARN.
        try await withApp(app) { _ in
            let scenario = try await makeOverrideOnlyScenario(studentID: "stu-ovr")
            try await applyGradeOverride(
                testSetupID: scenario.setupID, studentUserID: scenario.userID,
                percent: 80, note: nil, grantedByUserID: nil, on: app.db)
            let override = try #require(try await APIGradeOverride.query(on: app.db).first())
            override.brightspacePendingSince = Date().addingTimeInterval(-3600)
            try await override.save(on: app.db)

            let fake = FakeBrightSpaceGrading(userIDsByOrgDefinedId: ["stu-ovr": "d2l-ovr"])
            _ = try await sweep(client: fake)  // pushes the grade + writes a success log
            #expect(await fake.pushes.count == 1)

            // Instructor clears the override → a removal is queued.
            _ = try await clearGradeOverride(
                testSetupID: scenario.setupID, studentUserID: scenario.userID, on: app.db)
            let clearRow = try #require(try await APIBrightSpaceGradeClear.query(on: app.db).first())
            #expect(clearRow.brightspaceSyncPending == true)
            clearRow.brightspacePendingSince = Date().addingTimeInterval(-3600)
            try await clearRow.save(on: app.db)

            let processed = try await sweep(client: fake)

            #expect(processed == 1)
            #expect(await fake.clears == ["d2l-ovr"])
            // Queue row consumed.
            #expect(try await APIBrightSpaceGradeClear.query(on: app.db).count() == 0)
        }
    }

    @Test func overrideOnlyPushDefersWhenNoIdentityConnected() async throws {
        // With no connected sync identity the override-only push must defer, not
        // clear — the grade pushes once an instructor connects.
        try await withApp(app) { _ in
            let scenario = try await makeOverrideOnlyScenario(studentID: "stu-ovr")
            try await applyGradeOverride(
                testSetupID: scenario.setupID, studentUserID: scenario.userID,
                percent: 40, note: nil, grantedByUserID: nil, on: app.db)
            let override = try #require(try await APIGradeOverride.query(on: app.db).first())
            override.brightspacePendingSince = Date().addingTimeInterval(-3600)
            try await override.save(on: app.db)

            let processed = try await sweepWithNoIdentity()

            #expect(processed == 0)
            let reloaded = try #require(try await APIGradeOverride.query(on: app.db).first())
            #expect(reloaded.brightspaceSyncPending == true)
            #expect(reloaded.brightspaceSyncError == nil)
        }
    }

    @Test func gradeIsScaledToD2LGradeItemMaxPoints() async throws {
        // Chickadee grades the lab out of 20; the LEARN item is out of 10.
        // A 100% override must land as 10/10, not 20 (which would exceed the
        // item's max and 400 on a "can't exceed" item).
        try await withApp(app) { _ in
            let scenario = try await makeOverrideOnlyScenario(suiteTotal: 20, studentID: "stu-ovr")
            try await applyGradeOverride(
                testSetupID: scenario.setupID, studentUserID: scenario.userID,
                percent: 100, note: nil, grantedByUserID: nil, on: app.db)
            let override = try #require(try await APIGradeOverride.query(on: app.db).first())
            override.brightspacePendingSince = Date().addingTimeInterval(-3600)
            try await override.save(on: app.db)

            let fake = FakeBrightSpaceGrading(
                userIDsByOrgDefinedId: ["stu-ovr": "d2l-ovr"],
                gradeObject: BrightSpaceGradeObject(
                    id: "go-ovr", name: "Lab", maxPoints: 10, gradeType: "Numeric", canExceed: false))

            let processed = try await sweep(client: fake)

            #expect(processed == 1)
            let pushes = await fake.pushes
            #expect(pushes.count == 1)
            #expect(pushes.first?.earnedPoints == 10)  // 100% of /20, scaled onto the /10 item
        }
    }

    @Test func nonNumericGradeItemIsSkippedWithClearMessage() async throws {
        // Mapping a non-Numeric item (e.g. a SelectBox) must be refused with an
        // explanatory message instead of a bare D2L 400.
        try await withApp(app) { _ in
            let scenario = try await makeOverrideOnlyScenario(studentID: "stu-ovr")
            try await applyGradeOverride(
                testSetupID: scenario.setupID, studentUserID: scenario.userID,
                percent: 80, note: nil, grantedByUserID: nil, on: app.db)
            let override = try #require(try await APIGradeOverride.query(on: app.db).first())
            override.brightspacePendingSince = Date().addingTimeInterval(-3600)
            try await override.save(on: app.db)

            let fake = FakeBrightSpaceGrading(
                userIDsByOrgDefinedId: ["stu-ovr": "d2l-ovr"],
                gradeObject: BrightSpaceGradeObject(
                    id: "go-ovr", name: "Participation", maxPoints: nil, gradeType: "SelectBox"))

            let processed = try await sweep(client: fake)

            #expect(processed == 1)  // a terminal skip is "processed", not a failure
            let pushes = await fake.pushes
            #expect(pushes.isEmpty)
            let reloaded = try #require(try await APIGradeOverride.query(on: app.db).first())
            #expect(reloaded.brightspaceSyncPending == false)
            #expect(reloaded.brightspaceSyncError?.contains("Numeric") == true)
        }
    }

    @Test func transientPushFailureKeepsRowPendingForAutoRetry() async throws {
        // A 503 is transient — the row stays pending so the next sweep retries
        // automatically, without a manual "Retry failed".
        try await withApp(app) { _ in
            let scenario = try await makeConfiguredScenario(brightspaceUserID: "d2l-1")
            try await makePendingResult(
                submissionID: scenario.submissionID,
                json: pointsJSON(earned: 7, total: 10),
                pendingSince: Date().addingTimeInterval(-3600)
            )
            let fake = FakeBrightSpaceGrading(
                pushError: BrightSpaceSyncError.gradePushFailed(status: 503, body: "upstream down")
            )

            let processed = try await sweep(client: fake)

            #expect(processed == 0)
            let result = try #require(try await APIResult.query(on: app.db).first())
            #expect(result.brightspaceSyncPending == true)  // stays queued for retry
            #expect(result.brightspaceSyncError != nil)
            #expect(result.brightspaceSyncedAt == nil)
        }
    }

    @Test func terminalPushFailureClearsPendingFlag() async throws {
        // A 400 is terminal — retrying won't help, so the flag clears and the
        // row waits for a manual "Retry failed" after the cause is fixed.
        try await withApp(app) { _ in
            let scenario = try await makeConfiguredScenario(brightspaceUserID: "d2l-1")
            try await makePendingResult(
                submissionID: scenario.submissionID,
                json: pointsJSON(earned: 7, total: 10),
                pendingSince: Date().addingTimeInterval(-3600)
            )
            let fake = FakeBrightSpaceGrading(
                pushError: BrightSpaceSyncError.gradePushFailed(status: 400, body: "bad request")
            )

            let processed = try await sweep(client: fake)

            #expect(processed == 0)
            let result = try #require(try await APIResult.query(on: app.db).first())
            #expect(result.brightspaceSyncPending == false)  // not retried automatically
            #expect(result.brightspaceSyncError != nil)
        }
    }

    @Test func isRetryableSyncErrorClassification() async throws {
        // This class suite builds an Application per instance; wrap in withApp
        // so it shuts down deterministically (an un-shutdown app traps in
        // ServeCommand.deinit), even though the assertions are pure.
        try await withApp(app) { _ in
            #expect(isRetryableSyncError(BrightSpaceSyncError.gradePushFailed(status: 503, body: "")))
            #expect(isRetryableSyncError(BrightSpaceSyncError.gradePushFailed(status: 429, body: "")))
            #expect(isRetryableSyncError(BrightSpaceSyncError.gradePushFailed(status: 500, body: "")))
            #expect(!isRetryableSyncError(BrightSpaceSyncError.gradePushFailed(status: 400, body: "")))
            #expect(!isRetryableSyncError(BrightSpaceSyncError.gradePushFailed(status: 403, body: "")))
            #expect(!isRetryableSyncError(BrightSpaceSyncError.missingPoints))
            // A non-BrightSpace error (transport/timeout) is treated as transient.
            struct TransportError: Error {}
            #expect(isRetryableSyncError(TransportError()))
        }
    }

    @Test func scaledGradeIsRoundedToTwoDecimals() async throws {
        // 6/7 of a /7 suite onto a /10 item = 8.571428…, which must land as 8.57.
        try await withApp(app) { _ in
            let scenario = try await makeConfiguredScenario(brightspaceUserID: "d2l-1")
            try await makePendingResult(
                submissionID: scenario.submissionID,
                json: pointsJSON(earned: 6, total: 7),
                pendingSince: Date().addingTimeInterval(-3600)
            )
            let fake = FakeBrightSpaceGrading(
                gradeObject: BrightSpaceGradeObject(
                    id: "go-456", name: "Lab", maxPoints: 10, gradeType: "Numeric", canExceed: false))

            let processed = try await sweep(client: fake)

            #expect(processed == 1)
            let pushes = await fake.pushes
            let pushed = try #require(pushes.first?.earnedPoints)
            #expect(abs(pushed - 8.57) < 0.0001)
        }
    }
}
