// Core/AssignmentVisibility.swift
//
// The student-visibility / submission state of a published assignment.
//
// Replaces the historical `isOpen: Bool` with a three-state lifecycle:
//
//   closed  — not accepting student submissions. Students who previously
//             engaged keep read-only review access (e.g. after a deadline);
//             students who never engaged don't see it at all. Also the state
//             of a freshly created / cloned / edited assignment.
//   preview — a staff-only beta state. Student-facing behaviour is identical
//             to `.closed` (students cannot submit, and only previously-engaged
//             students can see it), but course staff (instructor / admin) may
//             test-submit to exercise the real grading path before publishing.
//   open    — visible to students and accepting submissions (subject to the
//             deadline / startsAt / extension logic in AssignmentDeadlineService).
//
// The intended lifecycle is a one-way street: closed → preview → open. The only
// transition the authoring service forbids is open → preview, which would
// require retracting visibility from students who already saw the assignment.

public enum AssignmentVisibility: String, Codable, Sendable, CaseIterable {
    case closed
    case preview
    case open

    /// Only `.open` accepts student submissions. `.preview` and `.closed` are
    /// equivalent from a student's perspective.
    public var acceptsStudentSubmissions: Bool { self == .open }

    /// Maps the legacy `isOpen` boolean onto the enum (`true` ⇒ `.open`,
    /// `false` ⇒ `.closed`). Pre-three-state data has no notion of `.preview`,
    /// so this never produces it; used when decoding old course bundles.
    public init(legacyIsOpen: Bool) {
        self = legacyIsOpen ? .open : .closed
    }

    /// How this visibility maps onto the per-viewer submission / access gate.
    ///
    /// - `treatAsOpen`: whether the assignment behaves as "open" for this viewer.
    ///   `.preview` is open only for staff; `.closed` is closed for everyone.
    /// - `honorsStartDate`: whether a future open date (`startsAt`) should hold
    ///   the assignment closed for this viewer.
    ///
    /// Staff testing a `.preview` assignment deliberately *bypass* the start-date
    /// gate: the open date governs when the assignment auto-publishes to
    /// *students*, not whether staff may exercise the grading path before then.
    /// Without this, a `.preview` assignment that also carries a scheduled open
    /// date is unreachable by the very staff who put it in preview to test it —
    /// the front gate in `isAssignmentOpenForUser` would hold it closed for
    /// everyone. (`.preview` is the only state where this matters: `.open`
    /// consumes `startsAt`, and `.closed`/`.preview`-for-students are already
    /// held closed by `treatAsOpen == false`.)
    public func submissionGate(isStaff: Bool) -> (treatAsOpen: Bool, honorsStartDate: Bool) {
        switch self {
        case .open: return (treatAsOpen: true, honorsStartDate: true)
        case .closed: return (treatAsOpen: false, honorsStartDate: true)
        case .preview: return (treatAsOpen: isStaff, honorsStartDate: !isStaff)
        }
    }
}
