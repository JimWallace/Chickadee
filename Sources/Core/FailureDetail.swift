// Core/FailureDetail.swift
//
// How much of a FAILING test a student is shown. Stored per suite entry (and
// on the family / case / check specs that generate entries), applied at
// results-display time by the server — never inside the generated script,
// which prints everything it knows so a re-run can be re-read under a
// different setting without regenerating the zip.
//
// The tier system decides WHETHER a student sees a test; this decides HOW
// MUCH of its failure they see. `.actualOnly` is what lets a test sit on the
// public tier without its message carrying the expected answer.

/// The student-facing detail level for one failing test.
public enum FailureDetail: String, Codable, Sendable, Equatable, CaseIterable {
    /// Everything the script printed: the message, the expected value, the
    /// student's value, any diff or traceback. The default.
    case full
    /// The student's own side only: their input echo, their output, the error
    /// their code raised. The expected value, a diff, or a threshold are
    /// withheld, since any of them would reveal the answer.
    case actualOnly
    /// The failure kind alone — "did not pass", "error", "timed out" — with
    /// no message text. The hint, if any, still shows.
    case verdictOnly

    /// The level an entry with no setting resolves to.
    public static let `default`: FailureDetail = .full

    /// Instructor-facing label for a select control.
    public var displayName: String {
        switch self {
        case .full: return "Full"
        case .actualOnly: return "Actual output only"
        case .verdictOnly: return "Verdict only"
        }
    }

    /// One sentence for a tooltip or a tool description.
    public var summary: String {
        switch self {
        case .full: return "the whole message, expected and actual values included"
        case .actualOnly: return "the student's own output and error, never the expected value or a diff"
        case .verdictOnly: return "only whether it passed, failed, errored or timed out"
        }
    }
}
