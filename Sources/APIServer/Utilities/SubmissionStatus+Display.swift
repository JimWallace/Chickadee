// APIServer/Utilities/SubmissionStatus+Display.swift
//
// The one display map for a submission's lifecycle state (UI audit #3007,
// findings 1 and 4). The result page's pending band and both history tables
// read it, so no view prints a raw `status` value.
//
// The map sits beside the enum rather than in `Core`, because the enum is an
// `APIServer` type: it names the `status` column of the submissions table.
//
// "Grading failed" is the reading of `.failed` on purpose: the raw word reads
// as "my tests failed", and it means the grader could not produce a result.

extension SubmissionStatus {
    /// The words a person reads for this state. No internal names (a
    /// "runner", a "worker") reach a student.
    var displayLabel: String {
        switch self {
        case .pending: "Queued"
        case .assigned, .running: "Grading"
        case .complete: "Graded"
        case .failed: "Grading failed"
        case .arena: "Waiting for its match"
        }
    }

    /// The badge classes for this state. Only `.failed` is a state where
    /// something went wrong, so only it takes `.tier-danger`; the rest are
    /// the neutral `.tier` (UI audit #3007, review decision 3).
    var badgeClass: String {
        switch self {
        case .failed: "tier tier-danger"
        case .pending, .assigned, .running, .complete, .arena: "tier"
        }
    }

    /// The badge classes for a stored raw value; an unknown value is neutral.
    static func badgeClass(forRaw raw: String) -> String {
        SubmissionStatus(rawValue: raw)?.badgeClass ?? "tier"
    }

    /// True while the submission has no result yet, so its result page polls.
    var awaitsResult: Bool {
        switch self {
        case .pending, .assigned, .running: true
        case .complete, .failed, .arena: false
        }
    }

    /// The display words for a stored raw value; an unknown value shows as is.
    static func displayLabel(forRaw raw: String) -> String {
        SubmissionStatus(rawValue: raw)?.displayLabel ?? raw
    }
}
