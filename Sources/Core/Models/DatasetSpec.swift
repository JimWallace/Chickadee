// Core/Models/DatasetSpec.swift
//
// Per-student dataset support (Phase 1 of the datasets/databases design —
// see docs/datasets.md).  A `DatasetSpec` marks one bundled support file as a
// per-student "dataset": the instructor uploads the full pool under a
// filename, and each student receives a deterministic slice of it under the
// *same* filename (so the notebook's `pd.read_csv("…")` line is unchanged).
//
// The spec is a save-time authoring concern.  The server materializes the
// per-student slice from the seed (see `DatasetMaterializer`) and delivers the
// resulting bytes to grading + the editor; the runner never sees a
// `DatasetSpec` (it is stripped by `TestProperties.runnerSanitized()`), only
// the already-materialized file.

/// How a per-student dataset slice is produced from the source support file.
///
/// - `rowSample`: a deterministic sample of `sampleSize` data rows from a
///   tabular (CSV) source, keyed to the per-(student, assignment) seed.  The
///   header row is always preserved and the chosen rows keep their original
///   order.
/// - `stratifiedSample`: the same, but the sample is apportioned across the
///   distinct values of `stratumColumn` so every category present in the pool
///   is still present in the student's slice.  A plain `rowSample` can drop a
///   rare category entirely, which turns a `groupby` exercise into a different
///   exercise for that student; this is the fix for that, and the reason the
///   `set_dataset` advice "pick a sample size large enough that every category
///   still appears" exists.
public enum DatasetKind: String, Codable, Sendable, Equatable, CaseIterable {
    case rowSample
    case stratifiedSample
}

/// Marks one bundled support file as a per-student dataset.
public struct DatasetSpec: Codable, Equatable, Sendable {
    /// The support filename that is a per-student dataset.  This is both the
    /// source's name in the test setup zip and the name the student sees; the
    /// per-student slice is delivered under this same name.
    public let file: String
    public let kind: DatasetKind
    /// Rows per student.  `nil` (or a value ≥ the row count) means "the whole
    /// file" — every student gets the full source.
    public let sampleSize: Int?
    /// The header name of the column whose distinct values are the strata, for
    /// `.stratifiedSample`.  Nil for `.rowSample`, which has no strata.
    ///
    /// Authoring surfaces refuse a `.stratifiedSample` spec without one, and
    /// refuse a column the file's header does not carry — a stratum column is
    /// only checkable against the file, and an instructor can fix a typo in
    /// seconds where a student cannot fix anything.  `DatasetMaterializer`
    /// still degrades rather than fails when it cannot find the column at
    /// delivery time, because by then the only reader is a student's grade.
    public let stratumColumn: String?
    /// Derivation steps applied to the student's rows after selection, in array
    /// order (see `DatasetTransform`).  Empty — the decoded default — means the
    /// student's slice carries the pool's values verbatim, which is every
    /// dataset authored before derivation existed.
    public let transforms: [DatasetTransform]
    /// The course library version this file was copied from, or nil for a file
    /// uploaded into this assignment by hand (docs/datasets-course-library.md).
    /// Only the library attach path writes it; every other door carries the
    /// stored value through unchanged.
    public let source: DatasetSource?
    /// Which seed selects the student's rows. `.assignment` is the decoded
    /// default, so every spec written before the course library keeps the bytes
    /// it delivers.
    public let scope: DatasetSliceScope

    public init(
        file: String, kind: DatasetKind = .rowSample, sampleSize: Int? = nil,
        stratumColumn: String? = nil, transforms: [DatasetTransform] = [],
        source: DatasetSource? = nil, scope: DatasetSliceScope = .assignment
    ) {
        self.file = file
        self.kind = kind
        self.sampleSize = sampleSize
        self.stratumColumn = stratumColumn
        self.transforms = transforms
        self.source = source
        self.scope = scope
    }

    /// The spec once the file is no longer attached from the library: the same
    /// selection and transforms with no source and the assignment scope. Nil
    /// when the spec exists only because of the attachment — no sample and no
    /// transforms — because the file then delivers the same bytes with no
    /// spec at all, and a spec with neither would be refused at the next edit.
    ///
    /// Detaching keeps a sample a student already receives. Removing the spec
    /// instead would hand every student the whole pool.
    public func withoutLibraryFields() -> DatasetSpec? {
        if sampleSize == nil, transforms.isEmpty { return nil }
        return DatasetSpec(
            file: file, kind: kind, sampleSize: sampleSize, stratumColumn: stratumColumn,
            transforms: transforms)
    }

    /// True when every student receives the same bytes: no sample and no
    /// transforms. The "shared" mode of docs/datasets-course-library.md §4.11,
    /// and the only mode an activity that compares students accepts.
    public var isShared: Bool {
        sampleSize == nil && transforms.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case file, kind, sampleSize, stratumColumn, transforms, source, scope
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        kind = try c.decodeIfPresent(DatasetKind.self, forKey: .kind) ?? .rowSample
        sampleSize = try c.decodeIfPresent(Int.self, forKey: .sampleSize)
        stratumColumn = try c.decodeIfPresent(String.self, forKey: .stratumColumn)
        transforms = try c.decodeIfPresent([DatasetTransform].self, forKey: .transforms) ?? []
        source = try c.decodeIfPresent(DatasetSource.self, forKey: .source)
        scope = try c.decodeIfPresent(DatasetSliceScope.self, forKey: .scope) ?? .assignment
    }

    /// Writes the same keys, in the same form, as the synthesized encoder did
    /// before the library fields existed, and adds each library field only when
    /// it differs from its default. A stored manifest that re-encodes must give
    /// the same bytes, because the manifest hash gates the retest fan-out and
    /// the runner cache.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(file, forKey: .file)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(sampleSize, forKey: .sampleSize)
        try c.encodeIfPresent(stratumColumn, forKey: .stratumColumn)
        try c.encode(transforms, forKey: .transforms)
        try c.encodeIfPresent(source, forKey: .source)
        if scope != .assignment {
            try c.encode(scope, forKey: .scope)
        }
    }
}
