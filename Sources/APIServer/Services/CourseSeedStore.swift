// APIServer/Services/CourseSeedStore.swift
//
// The per-(user, course) seed behind a student's course cohort
// (docs/datasets-course-library.md, D4 and slice 4), generated lazily. The
// same contract as `AssignmentSeedStore`: the UNIQUE(user_id, course_id)
// constraint settles a race, and the loser re-reads the winner.

import Core
import Fluent
import Foundation
import Vapor

enum CourseSeedStore {

    /// The seed for `(userID, courseID)`, created when absent.
    ///
    /// - Important: Do NOT call this inside an enclosing `db.transaction`. On
    ///   Postgres a failed INSERT aborts the whole transaction, so the
    ///   recover-by-re-read below would itself fail. Resolve the seed before a
    ///   transaction, as for `AssignmentSeedStore.ensureSeed`.
    static func ensureSeed(userID: UUID, courseID: UUID, on db: any Database) async throws -> String {
        if let existing = try await findSeed(userID: userID, courseID: courseID, on: db) {
            return existing
        }
        let newSeed = AssignmentSeedStore.generateSeedHex()
        do {
            try await APICoursePersonalizationSeed(userID: userID, courseID: courseID, seedValue: newSeed)
                .save(on: db)
            return newSeed
        } catch {
            if let winner = try await findSeed(userID: userID, courseID: courseID, on: db) {
                return winner
            }
            throw error
        }
    }

    /// The student's course seed when `manifest` has a course-scoped dataset,
    /// and nil otherwise. Every delivery path asks this one question, so a
    /// course seed exists only for a student who has met a course-scoped
    /// dataset, and an assignment without one never touches the table.
    static func seedIfNeeded(
        manifest: TestProperties, userID: UUID?, courseID: UUID, on db: any Database
    ) async throws -> String? {
        guard manifest.hasCourseScopedDatasets, let userID else { return nil }
        return try await ensureSeed(userID: userID, courseID: courseID, on: db)
    }

    private static func findSeed(userID: UUID, courseID: UUID, on db: any Database) async throws -> String? {
        try await APICoursePersonalizationSeed.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$courseID == courseID)
            .first()
            .map(\.seedValue)
    }
}
