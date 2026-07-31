// APIServer/Services/SlipDayStore.swift
//
// Reads/writes the slip-day ledger (#1228) and keeps the per-student
// `APIAssignmentExtension` row in step with it.
//
// A slip day is a student-initiated deadline extension drawn from a
// per-course budget: balance = course budget + enrollment adjustment −
// count(unrefunded spends in the course).  Spending writes a ledger row and
// writes (or updates) the ordinary extension row for (assignment, user) so
// every existing deadline gate — submission, dashboard visibility,
// release-tier results — keeps working untouched.  A staff refund stamps the
// ledger row `refunded_at` and recomputes or deletes the extension.
//
// Concurrency: stacking means there is no per-assignment UNIQUE constraint to
// absorb a lost race, so `spend` must be genuinely atomic.  Both `spend` and
// `refund` run one transaction that (on Postgres) first takes a `FOR UPDATE`
// row lock on the (user, course) enrollment row, serializing all balance
// mutations for that student in that course — the same idiom as the worker
// job claim (#1172).  The budget invariant is then asserted *after* the
// insert inside the same transaction, so an over-spend rolls back rather than
// committing.  On SQLite the row lock is a no-op and the single-writer lock
// provides the serialization: an interleaved second writer fails with BUSY /
// BUSY_SNAPSHOT (fails closed) instead of double-spending.
//
// - Important: Do NOT call `spend` / `refund` inside an enclosing
//   `db.transaction { … }` — they open their own transaction, and nested
//   transactions are not supported.  Every current caller passes a plain
//   pooled `Database`; keep it that way.

import Core
import Fluent
import Foundation
import SQLKit

enum SlipDayError: Error, Equatable {
    /// The student's remaining balance is below 1 (checked atomically — a
    /// concurrent double-submit surfaces here for the loser).
    case insufficientBalance
    /// No enrollment row for (user, course) — the caller's enrollment guard
    /// should make this unreachable.
    case notEnrolled
    /// The assignment has a staff-granted extension (an extension row exists
    /// that the slip-day ledger did not produce).  Accommodations and slip
    /// days do not mix — the offer is hidden and the spend refused.
    case staffExtensionPresent
    /// The assignment has no deadline, so there is nothing to extend.
    case assignmentHasNoDeadline
    /// The ledger row was already refunded (or a concurrent refund won).
    case alreadyRefunded
    case spendNotFound
}

/// What one successful spend produced, for the confirmation/audit trail.
struct SlipDaySpendReceipt: Sendable {
    /// The student's new effective deadline for the assignment.
    let newDeadline: Date
    /// Unrefunded spends now on this assignment (1 for a first spend).
    let spentOnAssignment: Int
    /// The student's remaining course-wide balance after this spend.
    let remainingBalance: Int
}

enum SlipDayStore {

    // MARK: - Reads

    /// Count of unrefunded spends for (user, course) — what the balance is
    /// charged for.
    static func unrefundedCount(
        userID: UUID, courseID: UUID, on db: Database
    ) async throws -> Int {
        try await APISlipDaySpend.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$courseID == courseID)
            .filter(\.$refundedAt == nil)
            .count()
    }

    /// Unrefunded spend count per assignment for (user, course) — drives the
    /// per-row offer state on the dashboard.
    static func unrefundedCountByAssignment(
        userID: UUID, courseID: UUID, on db: Database
    ) async throws -> [UUID: Int] {
        let rows = try await APISlipDaySpend.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$courseID == courseID)
            .filter(\.$refundedAt == nil)
            .all()
        var counts: [UUID: Int] = [:]
        for row in rows {
            counts[row.assignmentID, default: 0] += 1
        }
        return counts
    }

    /// The student's remaining balance.  Can go negative when staff claw back
    /// more days than remain unspent; display sites clamp at 0.
    static func balance(
        policy: SlipDayPolicy, adjustment: Int, unrefundedCount: Int
    ) -> Int {
        policy.daysPerStudent + adjustment - unrefundedCount
    }

    /// Every ledger row in the course (refunded included), newest first —
    /// the instructor roster ledger.
    static func courseLedger(
        courseID: UUID, on db: Database
    ) async throws -> [APISlipDaySpend] {
        try await APISlipDaySpend.query(on: db)
            .filter(\.$courseID == courseID)
            .sort(\.$spentAt, .descending)
            .all()
    }

    // MARK: - Spend

    /// Spends one slip day for `userID` on `assignment`, atomically: inserts
    /// the ledger row, asserts the budget invariant, and upserts the
    /// extension row, all in one transaction serialized per (user, course).
    /// Throws `SlipDayError` without writing anything when the spend is not
    /// allowed.  The caller is responsible for the non-racing gates (policy
    /// enabled, deadline passed, claim window open, caller is an enrolled
    /// non-staff student) — this re-checks only what a stale or concurrent
    /// request could corrupt: the balance and the staff-extension collision.
    static func spend(
        userID: UUID,
        assignment: APIAssignment,
        policy: SlipDayPolicy,
        on db: Database,
        now: Date = Date()
    ) async throws -> SlipDaySpendReceipt {
        guard let assignmentID = assignment.id else { throw SlipDayError.spendNotFound }
        guard let dueAt = assignment.dueAt else { throw SlipDayError.assignmentHasNoDeadline }
        let courseID = assignment.courseID

        return try await db.transaction { tx in
            // Serialize every balance mutation for this (user, course) on the
            // enrollment row (Postgres row lock; SQLite relies on its
            // single-writer lock — see the header comment).
            let adjustment = try await lockEnrollmentAndReadAdjustment(
                userID: userID, courseID: courseID, on: tx)

            // Staff-extension collision, re-checked inside the transaction: an
            // extension row with zero unrefunded slip-day spends was granted
            // by staff, and a slip day must not overwrite an accommodation.
            let priorOnAssignment = try await APISlipDaySpend.query(on: tx)
                .filter(\.$userID == userID)
                .filter(\.$assignmentID == assignmentID)
                .filter(\.$refundedAt == nil)
                .count()
            let extensionRow = try await APIAssignmentExtension.query(on: tx)
                .filter(\.$assignmentID == assignmentID)
                .filter(\.$userID == userID)
                .first()
            if priorOnAssignment == 0 && extensionRow != nil {
                throw SlipDayError.staffExtensionPresent
            }

            // The extension runs from the original deadline, not the moment
            // of the claim: the n-th stacked day produces dueAt + n × hours.
            let stackedCount = priorOnAssignment + 1
            let newDeadline = dueAt.addingTimeInterval(
                TimeInterval(stackedCount * policy.extensionHours) * 3600)

            let ledgerRow = APISlipDaySpend(
                userID: userID,
                courseID: courseID,
                assignmentID: assignmentID,
                extensionDueAt: newDeadline
            )
            try await ledgerRow.save(on: tx)

            // Budget invariant, asserted AFTER the insert inside the same
            // transaction (the count sees our own row): an over-spend throws,
            // which rolls the insert back.  With the per-(user, course)
            // serialization above, a lost race lands here as
            // `insufficientBalance` — never as two committed spends from a
            // one-day balance.
            let budget = policy.daysPerStudent + adjustment
            let spentInCourse = try await APISlipDaySpend.query(on: tx)
                .filter(\.$userID == userID)
                .filter(\.$courseID == courseID)
                .filter(\.$refundedAt == nil)
                .count()
            guard spentInCourse <= budget else {
                throw SlipDayError.insufficientBalance
            }

            try await upsertExtension(
                existing: extensionRow,
                assignmentID: assignmentID,
                userID: userID,
                extendedDueAt: newDeadline,
                stackedCount: stackedCount,
                on: tx)

            return SlipDaySpendReceipt(
                newDeadline: newDeadline,
                spentOnAssignment: stackedCount,
                remainingBalance: budget - spentInCourse
            )
        }
    }

    // MARK: - Refund

    /// Staff refund of one spend: stamps the ledger row and recomputes the
    /// extension row from the spends that remain — or deletes it when none
    /// do, so the student does not keep the extension for free.  Returns the
    /// refunded row.  Runs in the same per-(user, course) serialization as
    /// `spend`, so a refund cannot race a spend into a corrupt extension.
    @discardableResult
    static func refund(
        spendID: UUID,
        courseID: UUID,
        refundedBy staffUserID: UUID?,
        policy: SlipDayPolicy,
        on db: Database,
        now: Date = Date()
    ) async throws -> APISlipDaySpend {
        try await db.transaction { tx in
            guard
                let row = try await APISlipDaySpend.query(on: tx)
                    .filter(\.$id == spendID)
                    .filter(\.$courseID == courseID)
                    .first()
            else { throw SlipDayError.spendNotFound }

            _ = try await lockEnrollmentAndReadAdjustment(
                userID: row.userID, courseID: row.courseID, on: tx)

            // Single-use flip, same conditional-UPDATE idiom as the MCP token
            // consumption: only the request that transitions refunded_at from
            // NULL wins; a concurrent double-refund matches zero rows and the
            // re-read below reports `alreadyRefunded`.
            guard row.refundedAt == nil else { throw SlipDayError.alreadyRefunded }
            try await APISlipDaySpend.query(on: tx)
                .filter(\.$id == spendID)
                .filter(\.$refundedAt == nil)
                .set(\.$refundedAt, to: now)
                .set(\.$refundedByUserID, to: staffUserID)
                .update()
            guard
                let fresh = try await APISlipDaySpend.find(spendID, on: tx),
                fresh.refundedAt != nil
            else { throw SlipDayError.alreadyRefunded }

            try await recomputeExtensionAfterRefund(
                userID: row.userID,
                assignmentID: row.assignmentID,
                policy: policy,
                on: tx)
            return fresh
        }
    }

    // MARK: - Internals

    /// Locks the (user, course) enrollment row (Postgres `FOR UPDATE`; no-op
    /// lock on SQLite) and returns the row's slip-day adjustment.  Throws
    /// `notEnrolled` when no enrollment exists.
    private static func lockEnrollmentAndReadAdjustment(
        userID: UUID, courseID: UUID, on tx: Database
    ) async throws -> Int {
        if let sql = tx as? SQLDatabase, sql.dialect.name == "postgresql" {
            let locked = try await sql.raw(
                """
                SELECT id FROM course_enrollments
                WHERE user_id = \(bind: userID) AND course_id = \(bind: courseID)
                FOR UPDATE
                """
            ).first()
            guard locked != nil else { throw SlipDayError.notEnrolled }
        }
        guard
            let enrollment = try await APICourseEnrollment.query(on: tx)
                .filter(\.$userID == userID)
                .filter(\.$course.$id == courseID)
                .first()
        else { throw SlipDayError.notEnrolled }
        return enrollment.slipDaysAdjustment ?? 0
    }

    /// Writes the slip-day-produced extension row: updates the existing row's
    /// date in place (stacking, or a recompute) or creates a fresh one with
    /// no granting staff user and a self-serve note.
    private static func upsertExtension(
        existing: APIAssignmentExtension?,
        assignmentID: UUID,
        userID: UUID,
        extendedDueAt: Date,
        stackedCount: Int,
        on tx: Database
    ) async throws {
        let note = slipDayExtensionNote(stackedCount: stackedCount)
        if let existing {
            existing.extendedDueAt = extendedDueAt
            existing.note = note
            existing.grantedByUserID = nil
            try await existing.save(on: tx)
        } else {
            let row = APIAssignmentExtension(
                assignmentID: assignmentID,
                userID: userID,
                extendedDueAt: extendedDueAt,
                note: note,
                grantedByUserID: nil
            )
            try await row.save(on: tx)
        }
    }

    /// After a refund: the extension follows the remaining unrefunded spends —
    /// `dueAt + n × hours` for n remaining, deleted outright for n = 0 (or
    /// when the assignment lost its deadline, leaving nothing to compute
    /// from).  Recomputed with the *current* policy hours: a course that
    /// changed its hours-per-day mid-term re-anchors this student to the
    /// current policy, which the instructor ledger makes visible.
    private static func recomputeExtensionAfterRefund(
        userID: UUID,
        assignmentID: UUID,
        policy: SlipDayPolicy,
        on tx: Database
    ) async throws {
        let extensionRow = try await APIAssignmentExtension.query(on: tx)
            .filter(\.$assignmentID == assignmentID)
            .filter(\.$userID == userID)
            .first()
        guard let extensionRow else { return }

        let remaining = try await APISlipDaySpend.query(on: tx)
            .filter(\.$userID == userID)
            .filter(\.$assignmentID == assignmentID)
            .filter(\.$refundedAt == nil)
            .count()
        let dueAt = try await APIAssignment.find(assignmentID, on: tx)?.dueAt

        guard remaining > 0, let dueAt else {
            try await extensionRow.delete(on: tx)
            return
        }
        extensionRow.extendedDueAt = dueAt.addingTimeInterval(
            TimeInterval(remaining * policy.extensionHours) * 3600)
        extensionRow.note = slipDayExtensionNote(stackedCount: remaining)
        extensionRow.grantedByUserID = nil
        try await extensionRow.save(on: tx)
    }
}

/// The note stamped on a slip-day-produced extension row, so the instructor
/// student-drilldown (which shows extension notes) says where the extension
/// came from.
func slipDayExtensionNote(stackedCount: Int) -> String {
    stackedCount > 1 ? "Slip days ×\(stackedCount) (self-serve)" : "Slip day (self-serve)"
}

// MARK: - Offer logic (pure)

/// The state behind a visible "use a slip day" action: what the next spend
/// would produce.
struct SlipDayOffer: Equatable, Sendable {
    /// Unrefunded spends already on this assignment (0 for a first claim).
    let spentOnAssignment: Int
    /// The deadline the next spend would produce.
    let newDeadline: Date
    /// True when this claim stacks on an existing slip-day extension —
    /// drives the "Use another slip day" labelling.
    let isStacked: Bool
}

/// Decides whether the slip-day action is offered, from already-resolved
/// inputs.  Every condition from #1228:
///
///   - the course policy is enabled,
///   - the assignment has a deadline and it has passed,
///   - the student holds no *staff-granted* extension (an extension row the
///     ledger did not produce — `hasForeignExtension`),
///   - the remaining balance covers a day,
///   - `now` is still inside the window the student currently holds:
///     `dueAt + hours` for a first claim, `dueAt + n × hours` after n spends.
///
/// The window rule is what keeps the mechanic honest: the extension runs from
/// the original deadline, so a slip day cannot be banked and cashed later for
/// fresh time, and the offer disappears on its own with no expiry sweep.
func slipDayOffer(
    policy: SlipDayPolicy,
    dueAt: Date?,
    balance: Int,
    spentOnAssignment: Int,
    hasForeignExtension: Bool,
    now: Date = Date()
) -> SlipDayOffer? {
    guard policy.enabled else { return nil }
    guard let dueAt, dueAt <= now else { return nil }
    guard !hasForeignExtension else { return nil }
    guard balance >= 1 else { return nil }
    let heldWindowEnd = dueAt.addingTimeInterval(
        TimeInterval(max(spentOnAssignment, 1) * policy.extensionHours) * 3600)
    guard now < heldWindowEnd else { return nil }
    return SlipDayOffer(
        spentOnAssignment: spentOnAssignment,
        newDeadline: dueAt.addingTimeInterval(
            TimeInterval((spentOnAssignment + 1) * policy.extensionHours) * 3600),
        isStacked: spentOnAssignment >= 1
    )
}
