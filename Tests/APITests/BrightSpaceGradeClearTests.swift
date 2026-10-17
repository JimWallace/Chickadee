// Tests/APITests/BrightSpaceGradeClearTests.swift
//
// The branches of a queued BrightSpace grade REMOVAL that decide NOT to delete
// a grade in LEARN, plus the override helpers that queue and cancel a removal.
//
// `BrightSpaceGradeSyncTests.clearingOverrideAfterSyncRemovesGradeInLearn`
// covers the one path that does delete. Every other branch of
// `processPendingGradeClears` and `runGradeClear` keeps a grade in LEARN or
// defers, and a regression in any of them deletes a student's grade that
// should have stayed. These tests pin each of them.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

// MARK: - Recording client

/// A `BrightSpaceGrading` conformer that records pushes and removals. It serves
/// a fixed OrgDefinedId lookup table and a fixed classlist.
private actor RecordingGradingClient: BrightSpaceGrading {
    private let userIDsByOrgDefinedID: [String: String]
    private let classlist: [BrightSpaceClasslistEntry]
    private let clearError: (any Error)?
    private(set) var pushedUserIDs: [String] = []
    private(set) var clearedUserIDs: [String] = []

    init(
        userIDsByOrgDefinedID: [String: String] = [:],
        classlist: [BrightSpaceClasslistEntry] = [],
        clearError: (any Error)? = nil
    ) {
        self.userIDsByOrgDefinedID = userIDsByOrgDefinedID
        self.classlist = classlist
        self.clearError = clearError
    }

    func lookupUserID(orgDefinedId: String, on application: Application) async throws -> String? {
        userIDsByOrgDefinedID[orgDefinedId]
    }

    func fetchClasslist(
        orgUnitID: String, on application: Application
    ) async throws -> [BrightSpaceClasslistEntry] {
        classlist
    }

    func fetchGradeObject(
        orgUnitID: String, gradeObjectID: String, on application: Application
    ) async throws -> BrightSpaceGradeObject? {
        nil
    }

    func clearGrade(
        orgUnitID: String, gradeObjectID: String, bsUserID: String, on application: Application
    ) async throws {
        if let clearError { throw clearError }
        clearedUserIDs.append(bsUserID)
    }

    func pushGrade(
        orgUnitID: String,
        gradeObjectID: String,
        bsUserID: String,
        earnedPoints: Double,
        on application: Application
    ) async throws {
        pushedUserIDs.append(bsUserID)
    }
}

// MARK: - Suite

@Suite(.serialized, .timeLimit(.minutes(2)))
final class BrightSpaceGradeClearTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-bs-clear")
    }

    /// The student's LEARN identity in every scenario: OrgDefinedId to D2L id.
    private let studentNumber = "stu-clr"
    private let d2lUserID = "d2l-clr"

    private struct Scenario {
        let setupID: String
        let userID: UUID
    }

    /// A course and assignment wired to a LEARN grade item, and one student
    /// with no submission. The suite totals 10 points.
    private func makeScenario(gradeObjectID: String? = "go-clr") async throws -> Scenario {
        let course = try await makeTestCourse(on: app, code: "BSCLR")
        course.brightspaceOrgUnitID = "ou-clr"
        try await course.save(on: app.db)
        let courseID = try course.requireID()

        let setupID = "ts_\(UUID().uuidString.lowercased().prefix(8))"
        try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: Self.manifest(totalPoints: 10))
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: "Removal Lab")
        assignment.brightspaceGradeObjectID = gradeObjectID
        try await assignment.save(on: app.db)

        let user = try await makeTestUser(on: app, username: "clr_\(UUID().uuidString.lowercased().prefix(6))")
        user.studentID = studentNumber
        try await user.save(on: app.db)
        return Scenario(setupID: setupID, userID: try user.requireID())
    }

    private static func manifest(totalPoints: Int) -> String {
        #"""
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"t1.sh","points":\#(totalPoints)}],"timeLimitSeconds":10,"makefile":null}
        """#
    }

    /// Queues a removal that is already past the debounce window.
    @discardableResult
    private func queueRemoval(
        _ scenario: Scenario, pendingSince: Date = Date().addingTimeInterval(-3600)
    ) async throws -> APIBrightSpaceGradeClear {
        let row = APIBrightSpaceGradeClear(testSetupID: scenario.setupID, userID: scenario.userID)
        row.brightspacePendingSince = pendingSince
        try await row.save(on: app.db)
        return row
    }

    /// Records that Chickadee pushed a grade for the scenario's student, which
    /// is the gate `enqueueGradeClearIfOrphaned` requires.
    private func recordSuccessfulPush(_ scenario: Scenario) async throws {
        let entry = APIBrightSpaceSyncLog(
            courseID: nil, testSetupID: scenario.setupID, assignmentTitle: "Removal Lab",
            userID: scenario.userID, username: "student", orgUnitID: "ou-clr",
            gradeObjectID: "go-clr", points: 8, status: .success, detail: nil)
        try await entry.save(on: app.db)
    }

    private func sweep(
        client: (any BrightSpaceGrading)?, debounceSecs: TimeInterval = 90
    ) async throws -> Int {
        try await sweepBrightSpaceGradeSync(
            on: app.db,
            debounceSecs: debounceSecs,
            resolveClient: { _ in client },
            logger: app.logger,
            application: app
        )
    }

    private func pendingRemovals() async throws -> [APIBrightSpaceGradeClear] {
        try await APIBrightSpaceGradeClear.query(on: app.db).all()
    }

    // MARK: - The sweep keeps the grade
    //
    // Most tests below share one outcome: nothing deleted, no row left. They
    // are told apart by their scenario. `aSuccessfulRemovalIsRecordedInTheSyncLog`
    // is the positive control: the same scenario, with nothing changed, does
    // delete the grade.

    @Test func aPushForTheSameStudentInTheSameSweepWinsOverTheRemoval() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeScenario()
            try await applyGradeOverride(
                testSetupID: scenario.setupID, studentUserID: scenario.userID,
                percent: 70, note: nil, grantedByUserID: nil, on: app.db)
            let override = try #require(try await APIGradeOverride.query(on: app.db).first())
            override.brightspacePendingSince = Date().addingTimeInterval(-3600)
            try await override.save(on: app.db)
            // A removal queued for the same (student, setup) after the override.
            try await queueRemoval(scenario)

            let client = RecordingGradingClient(userIDsByOrgDefinedID: [studentNumber: d2lUserID])
            _ = try await sweep(client: client)

            #expect(await client.pushedUserIDs == [d2lUserID])
            #expect(await client.clearedUserIDs.isEmpty, "the push must win; nothing is deleted in LEARN")
            #expect(try await pendingRemovals().isEmpty, "the superseded removal is dropped")
        }
    }

    @Test func aRemovalIsDroppedWhenTheStudentHasSubmittedSinceItWasQueued() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeScenario()
            try await queueRemoval(scenario)
            try await makeTestSubmission(
                on: app, id: "sub_\(UUID().uuidString.lowercased().prefix(8))",
                setupID: scenario.setupID, userID: scenario.userID)

            let client = RecordingGradingClient(userIDsByOrgDefinedID: [studentNumber: d2lUserID])
            _ = try await sweep(client: client)

            #expect(await client.clearedUserIDs.isEmpty)
            #expect(try await pendingRemovals().isEmpty)
        }
    }

    @Test func aRemovalIsDroppedWhenAnOverrideWasSetSinceItWasQueued() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeScenario()
            try await queueRemoval(scenario)
            // Insert the override directly: `applyGradeOverride` would also
            // cancel the removal, and this test is about the sweep's own check.
            let override = APIGradeOverride(
                testSetupID: scenario.setupID, userID: scenario.userID,
                overridePercent: 90, note: nil, grantedByUserID: nil)
            try await override.save(on: app.db)

            let client = RecordingGradingClient(userIDsByOrgDefinedID: [studentNumber: d2lUserID])
            _ = try await sweep(client: client)

            #expect(await client.clearedUserIDs.isEmpty)
            #expect(try await pendingRemovals().isEmpty)
        }
    }

    @Test func aRemovalWaitsWhileNoSyncIdentityIsConnected() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeScenario()
            try await queueRemoval(scenario)

            let processed = try await sweep(client: nil)

            #expect(processed == 0)
            let row = try #require(try await pendingRemovals().first)
            #expect(row.brightspaceSyncPending == true, "the removal must run once an identity connects")
            #expect(row.brightspaceSyncError == nil)
        }
    }

    @Test func aRemovalWaitsOutTheDebounceWindow() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeScenario()
            try await queueRemoval(scenario, pendingSince: Date())

            let client = RecordingGradingClient(userIDsByOrgDefinedID: [studentNumber: d2lUserID])
            let processed = try await sweep(client: client, debounceSecs: 90)

            #expect(processed == 0)
            #expect(await client.clearedUserIDs.isEmpty)
            #expect(try await pendingRemovals().count == 1)
        }
    }

    @Test func aRemovalForAnAssignmentWithNoGradeItemDeletesNothingInLearn() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeScenario(gradeObjectID: nil)
            try await queueRemoval(scenario)

            let client = RecordingGradingClient(userIDsByOrgDefinedID: [studentNumber: d2lUserID])
            let processed = try await sweep(client: client)

            #expect(processed == 1)
            #expect(await client.clearedUserIDs.isEmpty)
            #expect(try await pendingRemovals().isEmpty)
        }
    }

    @Test func aRemovalForAStudentWithNoD2LAccountDeletesNothingInLearn() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeScenario()
            try await queueRemoval(scenario)

            let client = RecordingGradingClient()
            let processed = try await sweep(client: client)

            #expect(processed == 1)
            #expect(await client.clearedUserIDs.isEmpty)
            #expect(try await pendingRemovals().isEmpty)
        }
    }

    @Test func aStudentAbsentFromAPopulatedClasslistIsNotRemovedThroughTheGlobalLookup() async throws {
        // The global OrgDefinedId lookup would resolve the student, but a
        // populated classlist is the authority on who is in this org unit.
        try await withApp(app) { _ in
            let scenario = try await makeScenario()
            try await queueRemoval(scenario)

            let someoneElse = BrightSpaceClasslistEntry(
                orgDefinedID: "stu-other", username: "other", userID: "d2l-other")
            let client = RecordingGradingClient(
                userIDsByOrgDefinedID: [studentNumber: d2lUserID], classlist: [someoneElse])
            _ = try await sweep(client: client)

            #expect(await client.clearedUserIDs.isEmpty)
            #expect(try await pendingRemovals().isEmpty)
        }
    }

    @Test func aTransientRemovalFailureStaysPendingForTheNextSweep() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeScenario()
            try await queueRemoval(scenario)

            let client = RecordingGradingClient(
                userIDsByOrgDefinedID: [studentNumber: d2lUserID],
                clearError: BrightSpaceSyncError.gradePushFailed(status: 503, body: "unavailable"))
            _ = try await sweep(client: client)

            let row = try #require(try await pendingRemovals().first)
            #expect(row.brightspaceSyncPending == true)
            #expect(row.brightspaceSyncError != nil)
        }
    }

    @Test func aTerminalRemovalFailureStopsRetryingAndKeepsTheRow() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeScenario()
            try await queueRemoval(scenario)

            let client = RecordingGradingClient(
                userIDsByOrgDefinedID: [studentNumber: d2lUserID],
                clearError: BrightSpaceSyncError.gradePushFailed(status: 403, body: "forbidden"))
            _ = try await sweep(client: client)

            let row = try #require(try await pendingRemovals().first, "the row stays for a manual retry")
            #expect(row.brightspaceSyncPending == false)
            #expect(row.brightspaceSyncError != nil)
        }
    }

    @Test func aSuccessfulRemovalIsRecordedInTheSyncLog() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeScenario()
            try await queueRemoval(scenario)

            let client = RecordingGradingClient(userIDsByOrgDefinedID: [studentNumber: d2lUserID])
            _ = try await sweep(client: client)

            #expect(await client.clearedUserIDs == [d2lUserID])
            let log = try #require(
                try await APIBrightSpaceSyncLog.query(on: app.db)
                    .filter(\.$userID == scenario.userID)
                    .first())
            #expect(log.status == APIBrightSpaceSyncLog.Status.success.rawValue)
            #expect(log.points == nil, "a removal carries no points")
        }
    }

    // MARK: - Queueing and cancelling a removal

    @Test func noRemovalIsQueuedWhileTheStudentStillHasASubmission() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeScenario()
            try await recordSuccessfulPush(scenario)
            try await makeTestSubmission(
                on: app, id: "sub_\(UUID().uuidString.lowercased().prefix(8))",
                setupID: scenario.setupID, userID: scenario.userID)

            try await enqueueGradeClearIfOrphaned(
                testSetupID: scenario.setupID, studentUserID: scenario.userID, on: app.db)

            #expect(try await pendingRemovals().isEmpty)
        }
    }

    @Test func requeueingAFailedRemovalReArmsItAndKeepsItsPlaceInTheQueue() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeScenario()
            try await recordSuccessfulPush(scenario)
            let originalSince = Date().addingTimeInterval(-7200)
            let failed = try await queueRemoval(scenario, pendingSince: originalSince)
            failed.brightspaceSyncPending = false
            failed.brightspaceSyncError = "HTTP 403"
            try await failed.save(on: app.db)

            try await enqueueGradeClearIfOrphaned(
                testSetupID: scenario.setupID, studentUserID: scenario.userID, on: app.db)

            let rows = try await pendingRemovals()
            #expect(rows.count == 1, "one row per (student, setup)")
            let row = try #require(rows.first)
            #expect(row.brightspaceSyncPending == true)
            #expect(row.brightspaceSyncError == nil)
            let since = try #require(row.brightspacePendingSince)
            #expect(abs(since.timeIntervalSince(originalSince)) < 1)
        }
    }

    @Test func settingAnOverrideCancelsAQueuedRemoval() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeScenario()
            try await queueRemoval(scenario)

            try await applyGradeOverride(
                testSetupID: scenario.setupID, studentUserID: scenario.userID,
                percent: 60, note: nil, grantedByUserID: nil, on: app.db)

            #expect(try await pendingRemovals().isEmpty)
        }
    }

    @Test func clearingAnOverrideThatDoesNotExistQueuesNothing() async throws {
        try await withApp(app) { _ in
            let scenario = try await makeScenario()
            try await recordSuccessfulPush(scenario)

            let removed = try await clearGradeOverride(
                testSetupID: scenario.setupID, studentUserID: scenario.userID, on: app.db)

            #expect(removed == false)
            #expect(try await pendingRemovals().isEmpty)
        }
    }

    // MARK: - Override points

    @Test(arguments: [(0, 0.0), (37, 3.7), (100, 10.0)])
    func anOverridePercentConvertsToPointsAgainstTheSuiteTotal(percent: Int, points: Double) async throws {
        try await withApp(app) { _ in
            let scenario = try await makeScenario()
            let setup = try #require(try await APITestSetup.find(scenario.setupID, on: app.db))
            let converted = try #require(gradeOverridePoints(percent: percent, setup: setup))
            #expect(abs(converted - points) < 1e-9)
        }
    }

    @Test func anOverrideHasNoPointsWhenTheSuiteIsWorthNothing() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "BSZERO")
            let setup = try await makeTestSetup(
                on: app, id: "ts_\(UUID().uuidString.lowercased().prefix(8))",
                courseID: try course.requireID(), manifest: Self.manifest(totalPoints: 0))

            #expect(gradeOverridePoints(percent: 50, setup: setup) == nil)
        }
    }

    @Test func anOverrideHasNoPointsWhenTheManifestIsUnreadable() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "BSBAD")
            let setup = try await makeTestSetup(
                on: app, id: "ts_\(UUID().uuidString.lowercased().prefix(8))",
                courseID: try course.requireID(), manifest: "not json")

            #expect(gradeOverridePoints(percent: 50, setup: setup) == nil)
        }
    }
}
