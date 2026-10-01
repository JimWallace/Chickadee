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

enum LTIGradeSyncQueue {
    /// Queues `userIDs` for `testSetupID` when the assignment's course uses
    /// AGS.
    static func queue(userIDs: [UUID], testSetupID: String, on db: Database, now: Date = Date()) async throws {
        guard !userIDs.isEmpty, try await courseUsesLTIGrades(testSetupID: testSetupID, on: db) else { return }
        try await markPending(userIDs: userIDs, testSetupID: testSetupID, on: db, now: now)
    }

    /// Queues the owner of a newly graded submission. Validation and other
    /// non-student submissions have no grade to send.
    static func queue(submissionID: String, testSetupID: String, on db: Database) async throws {
        guard try await courseUsesLTIGrades(testSetupID: testSetupID, on: db),
            let submission = try await APISubmission.find(submissionID, on: db),
            submission.kind == APISubmission.Kind.student,
            let userID = submission.userID
        else { return }
        try await markPending(userIDs: [userID], testSetupID: testSetupID, on: db, now: Date())
    }

    /// Queues every student with a submission or an override for the setup:
    /// the "push all" action and a frozen class-goal bonus.
    static func queueAllStudents(testSetupID: String, on db: Database, now: Date = Date()) async throws {
        guard try await courseUsesLTIGrades(testSetupID: testSetupID, on: db) else { return }
        let submitters = try await APISubmission.query(on: db)
            .filter(\.$testSetupID == testSetupID)
            .filter(\.$kind == APISubmission.Kind.student)
            .all()
            .compactMap(\.userID)
        let overridden = try await APIGradeOverride.query(on: db)
            .filter(\.$testSetupID == testSetupID)
            .all()
            .map(\.userID)
        let userIDs = Array(Set(submitters + overridden))
        try await markPending(userIDs: userIDs, testSetupID: testSetupID, on: db, now: now)
    }

    /// Queues again the rows that failed because the student had not yet
    /// opened Chickadee from the LMS. Called when that student launches. The
    /// rule keys on the stored reason code, never on the sentence.
    static func retryFailed(userID: UUID, courseID: UUID, on db: Database, now: Date = Date()) async throws {
        let setupIDs = try await APIAssignment.query(on: db)
            .filter(\.$courseID == courseID)
            .all()
            .map(\.testSetupID)
        guard !setupIDs.isEmpty else { return }
        let failed = try await APILTIGradeSync.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$testSetupID ~~ setupIDs)
            .filter(\.$pending == false)
            .filter(\.$failureReason == LTIGradeSyncFailureReason.notLaunched.rawValue)
            .all()
        for row in failed {
            row.pending = true
            row.pendingSince = now
            row.error = nil
            row.failure = nil
            try await row.save(on: db)
        }
    }

    private static func courseUsesLTIGrades(testSetupID: String, on db: Database) async throws -> Bool {
        guard let assignment = try await assignmentByTestSetupID(testSetupID, on: db),
            let course = try await APICourse.find(assignment.courseID, on: db)
        else { return false }
        return course.usesLTIGrades
    }

    private static func markPending(userIDs: [UUID], testSetupID: String, on db: Database, now: Date) async throws {
        guard !userIDs.isEmpty else { return }
        var existing: [APILTIGradeSync] = []
        for chunk in chunkedForInFilter(userIDs) {
            existing += try await APILTIGradeSync.query(on: db)
                .filter(\.$testSetupID == testSetupID)
                .filter(\.$userID ~~ chunk)
                .all()
        }
        let byUser = Dictionary(existing.map { ($0.userID, $0) }, uniquingKeysWith: { first, _ in first })
        for userID in userIDs {
            if let row = byUser[userID] {
                // A row that is already waiting keeps its start time, so a
                // stream of submissions cannot hold the push back forever.
                if !row.pending { row.pendingSince = now }
                row.pending = true
                row.error = nil
                row.failure = nil
                try await row.save(on: db)
            } else {
                try await APILTIGradeSync(userID: userID, testSetupID: testSetupID, pendingSince: now).save(on: db)
            }
        }
    }
}
