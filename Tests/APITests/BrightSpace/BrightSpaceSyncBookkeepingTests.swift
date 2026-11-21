// Tests/APITests/BrightSpace/BrightSpaceSyncBookkeepingTests.swift
//
// The failure paths of the BrightSpace sync-row bookkeeping in
// `BrightSpaceGradeSyncService.swift`: a lost save while a sweep failure is
// recorded, a lost sync-log row, the "Sync now" requeue of errored override
// and removal rows, and the background sweep that "Sync now" starts. A save
// that fails must be logged and must not stop the other rows (#2776). No test
// reaches D2L: the background sweep runs where no sync identity is connected.

import Core
import Fluent
import Foundation
import Logging
import Testing
import VaporTesting

@testable import APIServer

// MARK: - Fakes

/// A sync row that is not a database model. Its save fails when `failsToSave`
/// is set, as a save does when the database connection drops.
private final class InMemorySyncRow: BrightSpaceSyncFlaggable {
    var brightspaceSyncPending: Bool?
    var brightspacePendingSince: Date?
    var brightspaceSyncedAt: Date?
    var brightspaceSyncError: String?
    let brightspaceSyncRowID: String
    let failsToSave: Bool
    private(set) var saves = 0

    init(id: String, failsToSave: Bool) {
        brightspaceSyncRowID = id
        self.failsToSave = failsToSave
        brightspaceSyncPending = true
        brightspaceSyncedAt = Date()
    }

    func save(on database: any Database) async throws {
        if failsToSave { throw BrightSpaceSyncError.notConfigured }
        saves += 1
    }
}

// MARK: - Suite

@Suite(.serialized, .timeLimit(.minutes(2))) struct BrightSpaceSyncBookkeepingTests {

    // MARK: Row identifiers

    @Test func overrideAndRemovalRowsNameThemselvesByTheirIDOrAQuestionMark() {
        let override = APIGradeOverride(testSetupID: "ts_x", userID: UUID(), overridePercent: 50)
        #expect(override.brightspaceSyncRowID == "?")
        let overrideID = UUID()
        override.id = overrideID
        #expect(override.brightspaceSyncRowID == overrideID.uuidString)

        let removal = APIBrightSpaceGradeClear(testSetupID: "ts_x", userID: UUID())
        #expect(removal.brightspaceSyncRowID == "?")
        let removalID = UUID()
        removal.id = removalID
        #expect(removal.brightspaceSyncRowID == removalID.uuidString)
    }

    // MARK: recordSweepFailure

    @Test func aLostSaveIsLoggedAndTheOtherRowsAreStillRecorded() async throws {
        try await withTestApp { app in
            let lost = InMemorySyncRow(id: "row-lost", failsToSave: true)
            let kept = InMemorySyncRow(id: "row-kept", failsToSave: false)
            let capture = CapturedLog()

            await recordSweepFailure(
                [lost, kept], error: BrightSpaceSyncError.missingPoints, db: app.db, logger: capture.logger)

            #expect(kept.saves == 1, "a lost save does not stop the next row")
            for row in [lost, kept] {
                #expect(row.brightspaceSyncPending == false, "a terminal failure clears the pending flag")
                #expect(row.brightspaceSyncedAt == nil)
                #expect(row.brightspaceSyncError == BrightSpaceSyncError.missingPoints.localizedDescription)
            }
            let lostLine = try #require(capture.record(.error, containing: "sync failure not recorded"))
            #expect(lostLine.metadata["row_id"] == "row-lost")
            #expect(!lostLine.message.contains("row-lost"), "the row id stays in metadata only")
            #expect(capture.records.filter { $0.level == .error }.count == 1)
            let summary = try #require(capture.record(.warning, containing: "terminal failure for 2 row(s)"))
            #expect(summary.metadata["row_ids"] == "row-lost, row-kept")
        }
    }

    @Test func aTransientFailureKeepsTheRowsPending() async throws {
        try await withTestApp { app in
            let row = InMemorySyncRow(id: "row-transient", failsToSave: false)
            let capture = CapturedLog()

            await recordSweepFailure(
                [row], error: BrightSpaceSyncError.gradePushFailed(status: 503, body: "busy"),
                db: app.db, logger: capture.logger)

            #expect(row.brightspaceSyncPending == true, "the next sweep retries a transient failure")
            #expect(capture.record(.warning, containing: "transient failure for 1 row(s)") != nil)
        }
    }

    // MARK: saveSyncLog

    @Test func aSyncLogRowThatCannotBeSavedIsLoggedAndDoesNotThrow() async throws {
        try await withTestApp { app in
            let userID = UUID()
            func entry() -> APIBrightSpaceSyncLog {
                APIBrightSpaceSyncLog(
                    courseID: nil, testSetupID: "ts_log", assignmentTitle: "Lab",
                    userID: userID, username: "student", orgUnitID: "ou-log",
                    gradeObjectID: "go-log", points: 4, status: .success, detail: nil)
            }
            let first = entry()
            try await first.save(on: app.db)
            // A second row with the same primary key: the insert fails.
            let duplicate = entry()
            duplicate.id = try first.requireID()
            let capture = CapturedLog()

            await saveSyncLog(duplicate, db: app.db, logger: capture.logger)

            let line = try #require(capture.record(.warning, containing: "sync log row"))
            #expect(line.message.contains("not saved"))
            #expect(line.metadata["user_id"] == userID.uuidString)
            #expect(try await APIBrightSpaceSyncLog.query(on: app.db).count() == 1)
        }
    }

    // MARK: requeueErroredGradePushes

    /// A course with one assignment, and two students. Returns the course ID,
    /// the setup ID and the two student IDs.
    private func makeCourseWithAssignment(
        code: String, on app: Application
    ) async throws -> (courseID: UUID, setupID: String, students: [UUID]) {
        let course = try await makeTestCourse(on: app, code: code)
        let courseID = try course.requireID()
        let setupID = "ts_\(UUID().uuidString.lowercased().prefix(8))"
        try await makeTestSetup(on: app, id: setupID, courseID: courseID)
        try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        var students: [UUID] = []
        for index in 0..<2 {
            let user = try await makeTestUser(on: app, username: "\(code.lowercased())_\(index)")
            students.append(try user.requireID())
        }
        return (courseID, setupID, students)
    }

    @discardableResult
    private func makeOverride(
        setupID: String, userID: UUID, error: String?, on app: Application
    ) async throws -> APIGradeOverride {
        let override = APIGradeOverride(testSetupID: setupID, userID: userID, overridePercent: 80)
        override.brightspaceSyncPending = false
        override.brightspacePendingSince = Date()
        override.brightspaceSyncError = error
        try await override.save(on: app.db)
        return override
    }

    @discardableResult
    private func makeRemoval(
        setupID: String, userID: UUID, error: String?, on app: Application
    ) async throws -> APIBrightSpaceGradeClear {
        let removal = APIBrightSpaceGradeClear(testSetupID: setupID, userID: userID)
        removal.brightspaceSyncPending = false
        removal.brightspacePendingSince = Date()
        removal.brightspaceSyncError = error
        try await removal.save(on: app.db)
        return removal
    }

    @Test func syncNowRequeuesErroredOverridesAndRemovalsInTheCourseOnly() async throws {
        try await withTestApp { app in
            let course = try await makeCourseWithAssignment(code: "RQA", on: app)
            let other = try await makeCourseWithAssignment(code: "RQB", on: app)

            let erroredOverride = try await makeOverride(
                setupID: course.setupID, userID: course.students[0], error: "HTTP 400", on: app)
            let blankOverride = try await makeOverride(
                setupID: course.setupID, userID: course.students[1], error: "", on: app)
            let erroredRemoval = try await makeRemoval(
                setupID: course.setupID, userID: course.students[0], error: "HTTP 404", on: app)
            let cleanRemoval = try await makeRemoval(
                setupID: course.setupID, userID: course.students[1], error: nil, on: app)
            let otherOverride = try await makeOverride(
                setupID: other.setupID, userID: other.students[0], error: "HTTP 400", on: app)
            let otherRemoval = try await makeRemoval(
                setupID: other.setupID, userID: other.students[0], error: "HTTP 404", on: app)

            try await requeueErroredGradePushes(courseUUID: course.courseID, on: app.db)

            for model in [erroredOverride, erroredRemoval] as [any BrightSpaceSyncFlaggable] {
                let row = try await reloadRow(model, on: app)
                #expect(row.pending == true, "an errored row is queued again")
                #expect(row.pendingSince == Date.distantPast, "and retried at once")
                #expect(row.error == nil)
            }
            let blank = try await reloadRow(blankOverride, on: app)
            #expect(blank.pending == false, "an empty error is not an error")
            #expect(blank.error?.isEmpty == true)
            let clean = try await reloadRow(cleanRemoval, on: app)
            #expect(clean.pending == false)
            for model in [otherOverride, otherRemoval] as [any BrightSpaceSyncFlaggable] {
                let row = try await reloadRow(model, on: app)
                #expect(row.pending == false, "another course is not touched")
                #expect(row.error != nil)
            }
        }
    }

    @Test func syncNowInACourseWithNoAssignmentsChangesNothing() async throws {
        try await withTestApp { app in
            let empty = try await makeTestCourse(on: app, code: "RQEMPTY")
            let other = try await makeCourseWithAssignment(code: "RQC", on: app)
            let override = try await makeOverride(
                setupID: other.setupID, userID: other.students[0], error: "HTTP 400", on: app)
            let removal = try await makeRemoval(
                setupID: other.setupID, userID: other.students[1], error: "HTTP 404", on: app)

            try await requeueErroredGradePushes(courseUUID: try empty.requireID(), on: app.db)

            for model in [override, removal] as [any BrightSpaceSyncFlaggable] {
                let row = try await reloadRow(model, on: app)
                #expect(row.pending == false)
                #expect(row.error != nil)
            }
        }
    }

    private struct StoredFlags {
        let pending: Bool?
        let pendingSince: Date?
        let error: String?
    }

    /// Reads a row's sync columns back from the database.
    private func reloadRow(_ model: any BrightSpaceSyncFlaggable, on app: Application) async throws -> StoredFlags {
        if let override = model as? APIGradeOverride {
            let row = try #require(try await APIGradeOverride.find(try override.requireID(), on: app.db))
            return StoredFlags(
                pending: row.brightspaceSyncPending, pendingSince: row.brightspacePendingSince,
                error: row.brightspaceSyncError)
        }
        let removal = try #require(model as? APIBrightSpaceGradeClear)
        let row = try #require(try await APIBrightSpaceGradeClear.find(try removal.requireID(), on: app.db))
        return StoredFlags(
            pending: row.brightspaceSyncPending, pendingSince: row.brightspacePendingSince,
            error: row.brightspaceSyncError)
    }

    // MARK: launchBackgroundBrightSpaceSweep

    @Test func syncNowStartsNoSweepWhenBrightSpaceIsNotConfigured() async throws {
        try await withTestApp { app in
            app.brightSpaceAppCredentials = nil

            await launchBackgroundBrightSpaceSweep(app)

            #expect(await app.backgroundWork.runningCount == 0)
        }
    }

    /// A pending result in a course with a grade item but no connected
    /// identity, and a pending result whose assignment has no grade item. Both
    /// were flagged just now, inside the debounce window.
    @Test func syncNowSweepsPastTheDebounceAndDefersACourseWithNoIdentity() async throws {
        try await withTestApp { app in
            app.brightSpaceAppCredentials = BrightSpaceAppCredentials(
                baseURL: "https://learn.example.edu", appID: "app", appKey: "key", debounceSecs: 3600)
            defer { app.brightSpaceAppCredentials = nil }

            let deferred = try await makePendingResult(
                code: "BGWIRED", orgUnitID: "ou-wired", gradeObjectID: "go-wired", on: app)
            let noItem = try await makePendingResult(
                code: "BGNOITEM", orgUnitID: "ou-noitem", gradeObjectID: nil, on: app)

            await launchBackgroundBrightSpaceSweep(app)
            // Wait for the sweep to end on its own: a drain would cancel it.
            for _ in 0..<400 where await app.backgroundWork.runningCount > 0 {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(await app.backgroundWork.runningCount == 0)

            let cleared = try #require(try await APIResult.find(try noItem.requireID(), on: app.db))
            #expect(cleared.brightspaceSyncPending == false, "the manual sweep does not wait out the debounce")
            let waiting = try #require(try await APIResult.find(try deferred.requireID(), on: app.db))
            #expect(waiting.brightspaceSyncPending == true, "no identity: the push waits for one")
            #expect(waiting.brightspaceSyncError == nil, "a deferral is not a failure")
        }
    }

    private func makePendingResult(
        code: String, orgUnitID: String, gradeObjectID: String?, on app: Application
    ) async throws -> APIResult {
        let course = try await makeTestCourse(on: app, code: code)
        course.brightspaceOrgUnitID = orgUnitID
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        let setupID = "ts_\(UUID().uuidString.lowercased().prefix(8))"
        try await makeTestSetup(on: app, id: setupID, courseID: courseID)
        let assignment = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        assignment.brightspaceGradeObjectID = gradeObjectID
        try await assignment.save(on: app.db)
        let user = try await makeTestUser(on: app, username: "\(code.lowercased())_student")
        user.studentID = "\(code)-001"
        try await user.save(on: app.db)
        let submissionID = "sub_\(UUID().uuidString.lowercased().prefix(8))"
        try await makeTestSubmission(
            on: app, id: submissionID, setupID: setupID, userID: try user.requireID())
        let result = try await makeTestResult(
            on: app, submissionID: submissionID,
            collectionJSON: #"{"earnedPoints":5,"totalPoints":10}"#)
        result.brightspaceSyncPending = true
        result.brightspacePendingSince = Date()
        try await result.save(on: app.db)
        return result
    }
}
