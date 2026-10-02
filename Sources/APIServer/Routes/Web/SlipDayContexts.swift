// APIServer/Routes/Web/SlipDayContexts.swift
//
// The view contexts behind the instructor Slip days tab
// (`instructor-slip-days.leaf`): the page context, one row per student with
// its ledger entries, the pip strip the roster also draws, and the
// class-wide totals. Built by `InstructorDashboardRoutes+SlipDays.swift`
// (#1716).

import Core
import Fluent
import Foundation
import Vapor

/// One ledger entry under a student row on the Slip days tab.
struct SlipDayLedgerSpendRow: Encodable {
    let id: String
    let assignmentTitle: String
    let spentAtText: String
    /// The cumulative deadline this spend produced at the time it was made.
    let extensionDueAtText: String
    let isRefunded: Bool
    let refundedAtText: String
    /// Precomputed `!isRefunded && canManageLedger` (LeafKit can't evaluate
    /// compound conditions).
    let canRefund: Bool
}

/// One student-role enrollment on the Slip days roster ledger.
struct SlipDayStudentRow: Encodable {
    let userID: String
    let displayName: String
    let username: String
    let used: Int
    /// Budget + adjustment − used.  Can be negative after a claw-back; shown
    /// as-is to staff (it signals the over-claw-back).
    let remaining: Int
    let total: Int
    let adjustment: Int
    /// Precomputed `!spends.isEmpty` (Leaf's `array.isEmpty` is unreliable).
    let hasSpends: Bool
    let spends: [SlipDayLedgerSpendRow]
    /// The student's own seeded avatar, at the roster size.
    let avatar: AvatarPresentation
    /// One pip per day in `total` (adjustments included): used days first, then
    /// the days still left, with granted extras that are still left marked apart.
    let pips: [SlipDayPip]
    /// "2 of 3 left" — the value the decorative pips illustrate.
    let leftText: String
    /// "+2 granted" / "−1 removed", empty when the adjustment is zero.
    let adjustmentText: String
    /// The refundable spends, for the row menu. Empty means no menu at all.
    let refundableSpends: [SlipDayLedgerSpendRow]
    let hasRefundable: Bool
}

/// One day in a student's budget, drawn as a pip. `state` is "used", "left" or
/// "extra" (a granted day that has not been spent).
struct SlipDayPip: Encodable, Equatable {
    let state: String
}

extension SlipDayPip {
    /// Pips for a student with `total` days of which `used` are spent and
    /// `extra` were granted by staff (the last `extra` days of the budget).
    static func pips(total: Int, used: Int, extra: Int) -> [SlipDayPip] {
        guard total > 0 else { return [] }
        let extras = min(max(extra, 0), total)
        return (0..<total).map { index in
            if index < used { return SlipDayPip(state: "used") }
            return SlipDayPip(state: index >= total - extras ? "extra" : "left")
        }
    }
}

struct InstructorSlipDaysContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeInstructorTab: String
    let hasActiveCourse: Bool
    let courseCode: String
    let enabled: Bool
    let daysPerStudent: Int
    let extensionHours: Int
    /// Whether release output waits out the claim window
    /// (`SlipDayPolicy.releaseRevealHold`) — the third settings checkbox.
    let releaseRevealHold: Bool
    /// Per-course instructor (or admin), non-archived — gates the policy form.
    let canEditSettings: Bool
    /// Non-archived — gates the ±1 and Refund buttons (TA floor is already
    /// guaranteed by the /instructor area middleware).
    let canManageLedger: Bool
    let settingsReadOnlyNote: String?
    /// Precomputed `!students.isEmpty` (Leaf's `array.isEmpty` is unreliable).
    let hasStudents: Bool
    let students: [SlipDayStudentRow]
    /// The facts card: "3 days", "24 hours", the release-hold wording, and the
    /// class-wide "11 of 93 spent" with its "8 students" note.
    let perStudentText: String
    let eachDayText: String
    let releaseHoldText: String
    let inUseText: String
    let inUseNote: String
    /// Whether the ledger has enough rows to earn a Filter box.
    let showFilter: Bool
    let flashSuccess: String?
    let flashError: String?
}

/// The class-wide totals behind the "In use" fact.
struct SlipDayTotals: Equatable {
    let spent: Int
    let budget: Int
    let studentsWithSpends: Int

    init(rows: [SlipDayStudentRow]) {
        spent = rows.reduce(0) { $0 + $1.used }
        budget = rows.reduce(0) { $0 + $1.total }
        studentsWithSpends = rows.filter { $0.used > 0 }.count
    }
}
