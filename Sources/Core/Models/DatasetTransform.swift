// Core/Models/DatasetTransform.swift
//
// Derivation, as distinct from selection (see docs/datasets.md).
//
// `DatasetKind` answers "which rows does this student get".  A transform
// answers "and what has been done to the values in them" — the step that turns
// the instructor's pool from a table into a template.  They are separate axes
// on purpose: "500 rows balanced by ward, then 2% of bp_systolic blanked" is
// two independent decisions, and a `DatasetKind` case per combination is how
// that enum reaches thirty cases.
//
// Selection runs first, then transforms in array order.  Both halves matter:
// transforming after selection means a rate applies to what the student
// actually receives rather than to the pool, and the order is load-bearing
// because blanking then jittering is not jittering then blanking.
//
// Two rules keep a transform from breaking the assignment it personalizes:
//
//   - It never touches the schema.  No column is added, removed, renamed or
//     reordered; rows and within-column values only.  The assignment ships
//     code written against column NAMES, and a student whose `df["systolic"]`
//     raises KeyError cannot fix that.
//   - Columns are named explicitly; there is no "all columns" wildcard.  An
//     instructor who blanks the column a notebook check asserts on has broken
//     their own assignment, and making them name it is what lets the save-time
//     check tell them so.

/// One derivation step applied to a student's slice after selection.
public struct DatasetTransform: Codable, Sendable, Equatable {

    /// What the step does to the cells it touches.
    ///
    /// - `missingValues`: blanks a deterministic subset of cells in the named
    ///   columns, so the student's data has holes to notice and handle.  Pure
    ///   string replacement — no type inference and no formatting decisions,
    ///   which is why it is the first derivation to ship.
    public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        case missingValues
    }

    public let kind: Kind
    /// The columns this step may alter, by header name.  Never empty in a
    /// saved spec — a transform naming no column would silently do nothing.
    public let columns: [String]
    /// Fraction of the student's rows affected, in `0 < rate <= 1`.  Authored
    /// as a `Double` because it is an authored number, but it never reaches a
    /// delivered byte as one: the materializer folds it to an integer count
    /// before any per-cell decision (see `DatasetMaterializer`).
    public let rate: Double?

    public init(kind: Kind, columns: [String], rate: Double? = nil) {
        self.kind = kind
        self.columns = columns
        self.rate = rate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        columns = try c.decodeIfPresent([String].self, forKey: .columns) ?? []
        rate = try c.decodeIfPresent(Double.self, forKey: .rate)
    }
}
