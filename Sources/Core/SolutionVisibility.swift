// Core/SolutionVisibility.swift
//
// Per-assignment policy for whether students may view the reference solution
// (the instructor's answer key) after the deadline.
//
// The policy decides only *that* a reveal happens; *when* it happens for one
// student is the server's reveal gate (`solutionVisibleToStudent`), which
// waits for the student's own effective deadline — extensions included — AND
// for the end of any slip-day claim window they could still use to buy more
// time. Without the second half, a student could read the answer key one
// minute after the deadline and then claim a slip day to submit it.

/// Whether and when an assignment's reference solution becomes visible to
/// students. Stored as a nullable raw string on `assignments`; nil resolves
/// to `.hidden` so no existing assignment changes behaviour.
public enum SolutionVisibility: String, Codable, Sendable, CaseIterable {
    /// Staff-only (the default): the solution is never served to students.
    case hidden
    /// Visible to each enrolled student once their own effective deadline has
    /// passed and no slip-day claim could still extend it. An assignment with
    /// no due date reveals immediately — the posted-lecture-material case.
    case afterDue
}
