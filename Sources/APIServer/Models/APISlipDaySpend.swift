// APIServer/Models/APISlipDaySpend.swift
//
// The slip-day ledger (#1228): one row per spend of one slip day.  A student
// stacking a second day on the same assignment produces a second row — there
// is deliberately NO unique constraint on (user, assignment).  The row's
// existence is the spent state (precedent: APISecretRevealUnlock); a staff
// refund does not delete the row but stamps `refunded_at`, so the ledger
// remains a complete history while refunded rows stop counting against the
// balance.
//
// Balance = course budget + enrollment adjustment − count(unrefunded rows in
// the course).  The ledger is course-scoped and courses are per-term, so the
// budget resets naturally at term rollover with no sweep.
//
// Each spend also writes/updates the ordinary `APIAssignmentExtension` row
// for (assignment, user) — the extension machinery is what actually reopens
// submission.  `extensionDueAt` records the cumulative deadline this spend
// produced at the time it was made.

import Fluent
import Vapor

final class APISlipDaySpend: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context.
    static let schema = "slip_day_spends"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "course_id")
    var courseID: UUID

    @Field(key: "assignment_id")
    var assignmentID: UUID

    /// The cumulative per-student deadline this spend produced:
    /// `assignment.dueAt + n × extensionHours` for the n-th unrefunded spend
    /// on the assignment at the time of spending.
    @Field(key: "extension_due_at")
    var extensionDueAt: Date

    @Timestamp(key: "spent_at", on: .create)
    var spentAt: Date?

    /// Set when course staff return this day to the student's budget.  A
    /// refunded row no longer counts against the balance and no longer backs
    /// the assignment's extension (the refund recomputes or deletes it).
    @OptionalField(key: "refunded_at")
    var refundedAt: Date?

    @OptionalField(key: "refunded_by_user_id")
    var refundedByUserID: UUID?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        courseID: UUID,
        assignmentID: UUID,
        extensionDueAt: Date
    ) {
        self.id = id
        self.userID = userID
        self.courseID = courseID
        self.assignmentID = assignmentID
        self.extensionDueAt = extensionDueAt
    }
}
