// Core/AvatarHatch.swift
//
// "Hatch a new bird": the one way a student's species changes
// (docs/avatar-species.md, decision 5, as superseded; docs/student-avatars.md,
// open question 1). A hatch draws a fresh bird of a different species. The
// face, the backdrop and the ring carry over, because the student chose them
// (#2588). A student may hatch `perTerm` times per Waterloo term.

public enum AvatarHatch {
    /// How many hatches a student has in one term.
    public static let perTerm = 3

    /// The key that groups a student's hatches by term: "2026-fall".
    public static func termKey(for term: AcademicTerm) -> String {
        "\(term.year)-\(term.season.rawValue)"
    }
}
