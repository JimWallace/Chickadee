// Core/DatasetSeedDerivation.swift
//
// The seed `DatasetMaterializer` uses for one spec
// (docs/datasets-course-library.md, D4).
//
// An assignment-scoped spec uses the per-(student, assignment) seed, as every
// spec did before the course library. A course-scoped spec uses the
// per-(student, course) seed, folded with the library slug. Folding in the slug
// keeps two library datasets with the same row count from giving one student
// the same row positions in both, which would be a visible pattern.
//
// The fold is SHA-256, not `Hasher`: the derived seed must be the same on every
// platform and every run, because the student's rows are a function of it.

import Foundation

public enum DatasetSeedDerivation {

    /// The seed that selects the student's rows for `spec`.
    ///
    /// A course-scoped spec with no course seed, or with no source to take a
    /// slug from, falls back to the assignment seed. The student then gets
    /// their per-assignment slice rather than the pool. That is the forgiving
    /// half of a pair: authoring refuses a course scope without a source
    /// (`DatasetSpecValidation.scopeIssue`), and every student-facing delivery
    /// path passes the course seed.
    public static func effectiveSeed(
        spec: DatasetSpec, assignmentSeedHex: String, courseSeedHex: String?
    ) -> String {
        guard spec.scope == .course, let source = spec.source,
            let courseSeedHex, !courseSeedHex.isEmpty
        else { return assignmentSeedHex }
        return courseScopedSeed(courseSeedHex: courseSeedHex, slug: source.slug)
    }

    /// The per-dataset seed for one student's course cohort: 64 lowercase hex
    /// characters, the same shape as an assignment seed.
    public static func courseScopedSeed(courseSeedHex: String, slug: String) -> String {
        sha256HexDigest(courseSeedHex + ":" + slug)
    }
}
