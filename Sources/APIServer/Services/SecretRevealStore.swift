// APIServer/Services/SecretRevealStore.swift
//
// Reads/writes the per-(user, assignment) secret-reveal token spend.
//
// Each student gets one reveal token per assignment (when the assignment's
// `secretRevealEnabled` toggle is on). Spending it inserts a row into
// `secret_reveal_unlocks`; the row's existence is the spent state, and staff
// re-grant by deleting it. `spendToken` is idempotent and race-safe: the
// UNIQUE(user_id, assignment_id) constraint means a lost INSERT race is
// swallowed (the winner's row already exists).
//
// - Important: Do NOT call these inside an enclosing `db.transaction { … }`.
//   On Postgres a failed INSERT aborts the entire transaction, so the
//   recover-by-re-check in `spendToken`'s `catch` would itself throw ("current
//   transaction is aborted"). Every current caller passes a plain pooled
//   `Database`; keep it that way.

import Fluent
import Foundation

enum SecretRevealStore {

    /// Record that `userID` spent their reveal token on `assignmentID`. No-op
    /// if a row already exists. Safe under concurrent double-submits.
    static func spendToken(
        userID: UUID,
        assignmentID: UUID,
        on db: Database
    ) async throws {
        if try await hasSpentToken(userID: userID, assignmentID: assignmentID, on: db) {
            return
        }
        let row = APISecretRevealUnlock(userID: userID, assignmentID: assignmentID)
        do {
            try await row.save(on: db)
        } catch {
            // UNIQUE constraint race: another request inserted first. The row
            // we wanted now exists, so the spend is still recorded.
            if try await hasSpentToken(userID: userID, assignmentID: assignmentID, on: db) {
                return
            }
            throw error
        }
    }

    /// Whether a spend row exists for `(userID, assignmentID)`.
    static func hasSpentToken(
        userID: UUID,
        assignmentID: UUID,
        on db: Database
    ) async throws -> Bool {
        try await APISecretRevealUnlock.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$assignmentID == assignmentID)
            .count() > 0
    }

    /// Staff re-grant: deletes the spend row so the student's token is
    /// available again. Returns true when a row existed.
    static func regrantToken(
        userID: UUID,
        assignmentID: UUID,
        on db: Database
    ) async throws -> Bool {
        let existing = try await APISecretRevealUnlock.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$assignmentID == assignmentID)
            .first()
        guard let existing else { return false }
        try await existing.delete(on: db)
        return true
    }

    /// All user IDs that have spent their token on this assignment (for the
    /// instructor roster page).
    static func spentUserIDs(
        assignmentID: UUID,
        on db: Database
    ) async throws -> Set<UUID> {
        let rows = try await APISecretRevealUnlock.query(on: db)
            .filter(\.$assignmentID == assignmentID)
            .all()
        return Set(rows.map(\.userID))
    }
}

/// The viewer-facing secret-reveal state for one (assignment, user) pair.
///
/// `revealed` is the single reveal gate consulted by both visibility surfaces
/// (web submission page + results JSON API): the toggle must be on AND the
/// token spent. An instructor turning the toggle off therefore re-hides
/// secret results without touching the spend row — re-enabling restores the
/// reveal.
struct SecretRevealState: Sendable {
    /// The assignment's `secretRevealEnabled` toggle.
    let enabled: Bool
    /// Whether the student's spend row exists.
    let spent: Bool

    var revealed: Bool { enabled && spent }

    static let none = SecretRevealState(enabled: false, spent: false)

    /// Resolve the reveal state for `userID` viewing `assignment`.
    ///
    /// Staff short-circuit to `.none` — they see all tiers regardless, so no
    /// DB hit. A nil assignment (setup with no published assignment) or nil
    /// user also resolves to `.none`. When the toggle is off the spend query
    /// is skipped: both the reveal and the spend offer are gated on `enabled`,
    /// so `spent` is never consulted in that case.
    static func resolve(
        assignment: APIAssignment?,
        userID: UUID?,
        isStaff: Bool,
        on db: Database
    ) async throws -> SecretRevealState {
        guard !isStaff, let assignment, let assignmentID = assignment.id, let userID else {
            return .none
        }
        guard assignment.secretRevealEnabled == true else {
            return .none
        }
        let spent = try await SecretRevealStore.hasSpentToken(
            userID: userID, assignmentID: assignmentID, on: db)
        return SecretRevealState(enabled: true, spent: spent)
    }
}
