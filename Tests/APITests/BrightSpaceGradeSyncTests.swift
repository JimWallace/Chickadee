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
import XCTVapor

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
    private let lookupError: (any Error)?
    private let pushError: (any Error)?
    private(set) var pushes: [RecordedPush] = []
    private(set) var lookupCount = 0

    init(
        userIDsByOrgDefinedId: [String: String] = [:],
        lookupError: (any Error)? = nil,
        pushError: (any Error)? = nil
    ) {
        self.userIDsByOrgDefinedId = userIDsByOrgDefinedId
        self.lookupError = lookupError
        self.pushError = pushError
    }

    func lookupUserID(orgDefinedId: String, on application: Application) async throws -> String? {
        lookupCount += 1
        if let lookupError { throw lookupError }
        return userIDsByOrgDefinedId[orgDefinedId]
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

    private func syncConfig(debounceSecs: TimeInterval = 90) -> BrightSpaceSyncConfig {
        BrightSpaceSyncConfig(
            baseURL: "https://example.test",
            appID: "app",
            appKey: "appKey",
            userID: "user",
            userKey: "userKey",
            debounceSecs: debounceSecs
        )
    }

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

    private func sweep(client: any BrightSpaceGrading, debounceSecs: TimeInterval = 90) async throws -> Int {
        try await sweepBrightSpaceGradeSync(
            on: app.db,
            client: client,
            config: syncConfig(debounceSecs: debounceSecs),
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

    @Test func pushFailureRecordsErrorOnResult() async throws {
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
            #expect(result.brightspaceSyncError != nil)
            #expect(result.brightspaceSyncedAt == nil)
        }
    }
}
