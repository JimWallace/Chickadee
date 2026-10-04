// APIServer/BrightSpace/LearnUnreachableReason.swift
//
// Why the roster-readiness sweep marked a student unreachable on LEARN. The
// sweep stores `storedDetail` on the enrollment row, and the Students tab reads
// the reason back from that detail. Both sides use the values in this file, so
// they cannot drift apart.

/// Why LEARN cannot receive a student's grade.
enum LearnUnreachableReason: CaseIterable, Equatable, Sendable {
    /// The student has a student ID, and the LEARN classlist does not list it.
    case notOnClasslist
    /// The student has no student ID, and LEARN does not list the username.
    case noMatch

    /// The reason for the reconciler's classification, or nil for a student
    /// that LEARN lists.
    init?(_ status: LearnRosterStatus) {
        switch status {
        case .onLearn: return nil
        case .notOnLearn: self = .notOnClasslist
        case .unverifiable: self = .noMatch
        }
    }

    /// The reason from the detail that the sweep stored. Only the exact
    /// "not on the classlist" detail gives `.notOnClasslist`, because only that
    /// case tells staff to remove the student. Any other detail gives
    /// `.noMatch`, whose advice does no harm if it is wrong.
    init(storedDetail: String?) {
        self = storedDetail == Self.notOnClasslist.storedDetail ? .notOnClasslist : .noMatch
    }

    /// The sentence that the sweep stores on the enrollment row. The LEARN tab
    /// shows it.
    var storedDetail: String {
        switch self {
        case .notOnClasslist:
            return "Not on the LEARN classlist (dropped, or not enrolled in the D2L course)."
        case .noMatch:
            return "Couldn't match to LEARN — add a student/org-defined ID, or check the username matches LEARN."
        }
    }

    /// The badge on the Students tab. It is a label of two or three words,
    /// never the stored sentence.
    var badge: String {
        switch self {
        case .notOnClasslist: return "Not on LEARN"
        case .noMatch: return "No LEARN match"
        }
    }

    /// Why, for the details line of the student's row.
    var reason: String {
        switch self {
        case .notOnClasslist: return "Dropped, or not enrolled in the LEARN course"
        case .noMatch: return "No student ID, and LEARN does not list the username"
        }
    }

    /// What staff can do, for the details line of the student's row.
    var advice: String {
        switch self {
        case .notOnClasslist: return "Remove from course if confirmed dropped"
        case .noMatch: return "Add a student ID to match LEARN"
        }
    }
}
