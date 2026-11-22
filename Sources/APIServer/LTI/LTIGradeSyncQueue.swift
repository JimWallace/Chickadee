// APIServer/LTI/LTIGradeSyncQueue.swift
//
// Puts (student, test setup) pairs on the AGS push queue (docs/lti-1-3.md
// "Grades through AGS"). Every event that can move a grade calls in here:
// a new result from either grading path, an override set or cleared, and a
// class-goal bonus that freezes. Each call is a no-op unless the assignment's
// course sends its grades through AGS, so a deployment with no LTI platform
// writes nothing.

import Fluent
import Foundation
import SQLKit

enum LTIGradeSyncQueue {
    /// Queues `userIDs` for `testSetupID` when the assignment's course uses
    /// AGS.
    static func queue(userIDs: [UUID], testSetupID: String, on db: any Database, now: Date = Date()) async throws {
        guard !userIDs.isEmpty, try await courseUsesLTIGrades(testSetupID: testSetupID, on: db) else { return }
        try await markPending(userIDs: userIDs, testSetupID: testSetupID, on: db, now: now)
    }

    /// Queues the owner of a newly graded submission, from the setup's course
    /// (nil when the setup has no assignment). Validation and other
    /// non-student submissions have no grade to send.
    static func queue(
        submissionID: String, course: APICourse?, testSetupID: String, on db: any Database
    ) async throws {
        guard course?.usesLTIGrades == true,
            let submission = try await APISubmission.find(submissionID, on: db),
            submission.kind == APISubmission.Kind.student,
            let userID = submission.userID
        else { return }
        try await markPending(userIDs: [userID], testSetupID: testSetupID, on: db, now: Date())
    }

    /// Queues every student with a submission or an override for the setup:
    /// the "push all" action and a frozen class-goal bonus.
    static func queueAllStudents(testSetupID: String, on db: any Database, now: Date = Date()) async throws {
        guard try await courseUsesLTIGrades(testSetupID: testSetupID, on: db) else { return }
        // Only the user column, once per user: a setup's submissions are its
        // whole history.
        let submitters = try await APISubmission.query(on: db)
            .filter(\.$testSetupID == testSetupID)
            .filter(\.$kind == APISubmission.Kind.student)
            .filter(\.$userID != nil)
            .unique()
            .all(\.$userID)
            .compactMap(\.self)
        let overridden = try await APIGradeOverride.query(on: db)
            .filter(\.$testSetupID == testSetupID)
            .unique()
            .all(\.$userID)
        let userIDs = Array(Set(submitters + overridden))
        try await markPending(userIDs: userIDs, testSetupID: testSetupID, on: db, now: now)
    }

    /// Queues again the rows that failed because the student had not yet
    /// opened Chickadee from the LMS. Called when that student launches. The
    /// rule keys on the stored reason code, never on the sentence.
    static func retryFailed(userID: UUID, courseID: UUID, on db: any Database, now: Date = Date()) async throws {
        let setupIDs = try await APIAssignment.query(on: db)
            .filter(\.$courseID == courseID)
            .all()
            .map(\.testSetupID)
        guard !setupIDs.isEmpty else { return }
        // One statement for every failed row of the student in the course.
        try await APILTIGradeSync.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$testSetupID ~~ setupIDs)
            .filter(\.$pending == false)
            .filter(\.$failureReason == LTIGradeSyncFailureReason.notLaunched.rawValue)
            .set(\.$pending, to: true)
            .set(\.$pendingSince, to: now)
            .set(\.$error, to: nil)
            .set(\.$failureReason, to: nil)
            .update()
    }

    private static func courseUsesLTIGrades(testSetupID: String, on db: any Database) async throws -> Bool {
        try await gradePushTarget(testSetupID: testSetupID, on: db).1?.usesLTIGrades == true
    }

    /// Puts each user's row for the setup in the pending state, in one
    /// statement per chunk: an insert for a user with no row, an update for
    /// one with a row (on the unique `(user_id, test_setup_id)`). A row that
    /// is already waiting keeps its start time, so a stream of submissions
    /// cannot hold the push back forever.
    private static func markPending(userIDs: [UUID], testSetupID: String, on db: any Database, now: Date) async throws {
        let distinct = Array(Set(userIDs))
        guard !distinct.isEmpty else { return }
        guard let sql = db as? (any SQLDatabase) else {
            throw AppError.internalFailure(reason: "The LTI grade sync queue needs a SQL database.")
        }
        let table = APILTIGradeSync.schema
        for chunk in chunkedForInFilter(distinct) {
            var insert = sql.insert(into: table)
                .columns("id", "user_id", "test_setup_id", "pending", "pending_since")
            for userID in chunk {
                insert = insert.values([
                    SQLBind(UUID()), SQLBind(userID), SQLBind(testSetupID), SQLBind(true), SQLBind(now),
                ])
            }
            try await insert
                .onConflict(with: ["user_id", "test_setup_id"]) { conflict in
                    conflict
                        .set(
                            "pending_since",
                            to: SQLRaw(
                                "CASE WHEN \(table).pending THEN \(table).pending_since ELSE EXCLUDED.pending_since END"
                            )
                        )
                        .set("pending", to: true)
                        .set("error", to: SQLLiteral.null)
                        .set("failure_reason", to: SQLLiteral.null)
                }
                .run()
        }
    }
}
