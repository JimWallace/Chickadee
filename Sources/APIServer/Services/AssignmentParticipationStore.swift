// APIServer/Services/AssignmentParticipationStore.swift
//
// Reads/writes the durable per-(user, assignment) participation record.
//
// `recordFirstAccess` is idempotent and race-safe: the UNIQUE(user_id,
// assignment_id) constraint on `assignment_participations` means a lost
// INSERT race is swallowed (the winner's row already exists). Callers
// invoke it whenever a student is *allowed* to open an assignment, so a
// row only ever appears for an assignment the student could actually
// reach — which is what keeps closed, never-opened labs unrecorded.

import Fluent
import Foundation

enum AssignmentParticipationStore {

    /// Record that `userID` has engaged with `assignmentID`. No-op if a row
    /// already exists. Safe under concurrent first-access requests.
    static func recordFirstAccess(
        userID: UUID,
        assignmentID: UUID,
        on db: Database
    ) async throws {
        if try await hasParticipation(userID: userID, assignmentID: assignmentID, on: db) {
            return
        }
        let row = APIAssignmentParticipation(userID: userID, assignmentID: assignmentID)
        do {
            try await row.save(on: db)
        } catch {
            // UNIQUE constraint race: another request inserted first. The row
            // we wanted now exists, so the access is still recorded.
            if try await hasParticipation(userID: userID, assignmentID: assignmentID, on: db) {
                return
            }
            throw error
        }
    }

    /// Whether a participation row exists for `(userID, assignmentID)`.
    static func hasParticipation(
        userID: UUID,
        assignmentID: UUID,
        on db: Database
    ) async throws -> Bool {
        try await APIAssignmentParticipation.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$assignmentID == assignmentID)
            .count() > 0
    }
}
