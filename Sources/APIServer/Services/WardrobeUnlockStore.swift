// APIServer/Services/WardrobeUnlockStore.swift
//
// Grants the wardrobe items a student has earned (Core/WardrobeItem.swift,
// #2592) and reads the ones already stored. Grants run when the account page
// loads, never while a result is written, so a cosmetic cannot fail a grade.
// A stored unlock is never taken back.

import Core
import Fluent
import Foundation

enum WardrobeUnlockStore {

    /// The items `userID` has stored.
    static func unlocked(for userID: UUID, on db: any Database) async throws -> Set<WardrobeItem> {
        let rows = try await APIWardrobeUnlock.query(on: db).filter(\.$userID == userID).all()
        return Set(rows.compactMap { WardrobeItem(rawValue: $0.item) })
    }

    /// What `userID`'s own graded student submissions show.
    static func progress(for userID: UUID, on db: any Database) async throws -> WardrobeProgress {
        let results = try await APIResult.query(on: db)
            .join(APISubmission.self, on: \APIResult.$submissionID == \APISubmission.$id)
            .filter(APISubmission.self, \.$userID == userID)
            .filter(APISubmission.self, \.$kind == APISubmission.Kind.student)
            .all()
        let submissions = try results.map { try $0.joined(APISubmission.self) }
        let dueDates = try await dueDates(of: Set(submissions.map(\.testSetupID)), on: db)
        let concepts = try await concepts(of: Set(submissions.map(\.testSetupID)), on: db)
        let graded = zip(results, submissions).map { result, submission in
            WardrobeProgress.Graded(
                assignmentID: submission.testSetupID,
                // A row with no attempt number is not counted as a first try.
                attemptNumber: submission.attemptNumber ?? 0,
                passCount: result.passCount ?? 0,
                totalTests: result.totalTests ?? 0,
                // The server's own receipt time, so a student cannot forge it.
                secondsBeforeDue: secondsBeforeDue(submission.submittedAt, dueDates[submission.testSetupID]),
                concept: concepts[submission.testSetupID])
        }
        return WardrobeProgress(graded: graded)
    }

    /// The due date of each test setup's assignment. A setup whose
    /// assignment has no due date is not in the result. The early rule reads
    /// the assignment's own due date, not a student's extension.
    private static func dueDates(of testSetupIDs: Set<String>, on db: any Database) async throws -> [String: Date] {
        guard !testSetupIDs.isEmpty else { return [:] }
        let assignments = try await APIAssignment.query(on: db)
            .filter(\.$testSetupID ~~ Array(testSetupIDs))
            .filter(\.$dueAt != nil)
            .all()
        var dueDates: [String: Date] = [:]
        for assignment in assignments {
            dueDates[assignment.testSetupID] = assignment.dueAt
        }
        return dueDates
    }

    private static func secondsBeforeDue(_ submittedAt: Date?, _ dueAt: Date?) -> Double? {
        guard let submittedAt, let dueAt else { return nil }
        return dueAt.timeIntervalSince(submittedAt)
    }

    /// The concept each test setup's assignment is tagged with. A setup
    /// whose assignment has no concept is not in the result.
    private static func concepts(
        of testSetupIDs: Set<String>, on db: any Database
    ) async throws -> [String: AssignmentConcept] {
        guard !testSetupIDs.isEmpty else { return [:] }
        let assignments = try await APIAssignment.query(on: db)
            .filter(\.$testSetupID ~~ Array(testSetupIDs))
            .filter(\.$conceptRaw != nil)
            .all()
        var concepts: [String: AssignmentConcept] = [:]
        for assignment in assignments {
            concepts[assignment.testSetupID] = assignment.concept
        }
        return concepts
    }

    /// Stores every item `userID` has earned and not yet stored, and returns
    /// what is stored afterwards, so the page offers exactly what the save
    /// route accepts. A failed write keeps the page: the next load grants
    /// again, and the unique index stores an item once when two requests race.
    static func grantEarned(for userID: UUID, on db: any Database) async throws -> Set<WardrobeItem> {
        let stored = try await unlocked(for: userID, on: db)
        guard stored.count < WardrobeItem.allCases.count else { return stored }
        let missing = WardrobeItem.earned(by: try await progress(for: userID, on: db)).subtracting(stored)
        guard !missing.isEmpty else { return stored }
        for item in WardrobeItem.allCases where missing.contains(item) {
            try? await APIWardrobeUnlock(userID: userID, item: item).save(on: db)
        }
        return try await unlocked(for: userID, on: db)
    }
}
