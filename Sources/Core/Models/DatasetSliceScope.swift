// Core/Models/DatasetSliceScope.swift
//
// Which seed selects a student's rows (docs/datasets-course-library.md, D4 and
// D5).

/// Which per-student seed a dataset slice is keyed to.
///
/// - `assignment`: the per-(student, assignment) seed. A student's rows differ
///   from one assignment to the next. This is the default, and every spec
///   written before the course library decodes to it.
/// - `course`: the per-(student, course) seed, derived per library slug. A
///   student gets the same rows of one library dataset in every assignment
///   that attaches it, which is the course cohort. Only a spec with a
///   `DatasetSource` can have this scope, because the slug is part of the
///   derivation.
public enum DatasetSliceScope: String, Codable, Sendable, Equatable, CaseIterable {
    case assignment
    case course
}
