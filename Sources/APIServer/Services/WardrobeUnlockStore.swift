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
        let graded = try results.map { result in
            let submission = try result.joined(APISubmission.self)
            return WardrobeProgress.Graded(
                assignmentID: submission.testSetupID,
                attemptNumber: submission.attemptNumber ?? 1,
                passCount: result.passCount ?? 0,
                totalTests: result.totalTests ?? 0)
        }
        return WardrobeProgress(graded: graded)
    }

    /// Stores every item `userID` has earned and not yet stored, and returns
    /// everything stored. A failed write keeps the page: the next load grants
    /// again, and the unique index stores an item once.
    static func grantEarned(for userID: UUID, on db: any Database) async throws -> Set<WardrobeItem> {
        let stored = try await unlocked(for: userID, on: db)
        let earned = WardrobeItem.earned(by: try await progress(for: userID, on: db))
        let missing = earned.subtracting(stored)
        for item in WardrobeItem.allCases where missing.contains(item) {
            try? await APIWardrobeUnlock(userID: userID, item: item).save(on: db)
        }
        return stored.union(earned)
    }
}
