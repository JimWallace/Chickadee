// APIServer/Services/SlipDayClaimState.swift
//
// The slip-day inputs a post-deadline reveal gate needs for one (student,
// assignment) pair, already loaded. Two callers build one: the database
// loader (`slipDayClaimState(for:user:on:)`, one query set per pair) and the
// dashboard (from its batch-loaded `DashboardSlipDayData`, no per-row query).
// Both hand it to the same pure resolvers (`postDeadlineRevealDeadline`,
// `solutionVisibleToStudent(assignment:extensionDueAt:slipDay:now:)`), so the
// reveal rule has one body (#2665).

import Core
import Foundation

/// A student's slip-day position on one assignment. Nil, where an API takes
/// an optional one, means no claim is reachable at all: slip days are off,
/// the course is missing or archived, the assignment is a staff preview, or
/// the viewer is not enrolled.
struct SlipDayClaimState: Equatable {
    /// The course's slip-day policy.
    let policy: SlipDayPolicy
    /// Course-wide remaining balance: budget plus adjustment minus unrefunded
    /// spends. Can be negative after a staff claw-back.
    let balance: Int
    /// Unrefunded spends on this assignment.
    let spentOnAssignment: Int

    /// The end of the claim window this student holds at `now`
    /// (`slipDayClaimWindowCeiling`). A staff-granted extension with no
    /// spend behind it ends the claim path, so `extensionDueAt` is an input.
    func claimWindowCeiling(dueAt: Date?, extensionDueAt: Date?, now: Date) -> Date? {
        slipDayClaimWindowCeiling(
            policy: policy,
            dueAt: dueAt,
            balance: balance,
            spentOnAssignment: spentOnAssignment,
            hasForeignExtension: extensionDueAt != nil && spentOnAssignment == 0,
            now: now)
    }
}
