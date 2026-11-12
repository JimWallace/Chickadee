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
/// - `partition`: the file split into `partCount` disjoint parts, one part per
///   student. Data row `i` is in part `i mod partCount`, so every part spans
///   the whole file in order. The part is not chosen by a seed: it is dealt,
///   like a class composite's slot (docs/datasets-course-library.md §4.11).
public enum DatasetKind: String, Codable, Sendable, Equatable, CaseIterable {
    case rowSample
    case stratifiedSample
    case partition
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
    /// How many parts a `.partition` spec splits the file into. Nil for the
    /// other kinds, which authoring refuses to store with one.
    public let partCount: Int?
    /// The file's format. `.csv` is the decoded default, so every spec written
    /// before FHIR support keeps its bytes (docs/fhir-datasets-plan.md §6).
    /// Only the library attach path writes another value; every other door
    /// carries the stored value through unchanged, as for `source`.
    public let format: DatasetFormat
    /// A stored format value this server does not know, kept as written, or
    /// nil. A newer server wrote it (docs/dataset-kinds-plan.md §5). The spec
    /// still decodes, delivers the file whole and re-encodes the same value,
    /// so a blue-green overlap or a rollback never fails a manifest; the
    /// save-time checks refuse to store a new edit of it. `format` reads
    /// `.csv` for such a spec, and no reader may select by it: they read
    /// `capabilities`.
    public let unknownFormat: String?

    /// The stored format value, as written: an unknown one too. What a tool
    /// or a page reports, so a format this server does not know is not shown
    /// as CSV.
    public var formatName: String { unknownFormat ?? format.rawValue }

    /// The media type of the delivered file. A format this server does not
    /// know is sent as bytes.
    public var mediaType: String { unknownFormat == nil ? format.mediaType : "application/octet-stream" }

    /// What this spec's format lets it do. A spec of an unknown format
    /// selects nothing.
    public var capabilities: DatasetCapabilities {
        unknownFormat == nil ? format.capabilities : .whole(unitName: "record")
    }

    public init(
        file: String, kind: DatasetKind = .rowSample, sampleSize: Int? = nil,
        stratumColumn: String? = nil, transforms: [DatasetTransform] = [],
        source: DatasetSource? = nil, scope: DatasetSliceScope = .assignment, partCount: Int? = nil,
        format: DatasetFormat = .csv, unknownFormat: String? = nil
    ) {
        self.file = file
        self.kind = kind
        self.sampleSize = sampleSize
        self.stratumColumn = stratumColumn
        self.transforms = transforms
        self.source = source
        self.scope = scope
        self.partCount = partCount
        self.format = format
        self.unknownFormat = unknownFormat
    }

    /// A rebuild that carries `unknownFormat`, for the rebuilds in this file.
    private init(rebuilding spec: DatasetSpec, source: DatasetSource?, scope: DatasetSliceScope) {
        self.file = spec.file
        self.kind = spec.kind
        self.sampleSize = spec.sampleSize
        self.stratumColumn = spec.stratumColumn
        self.transforms = spec.transforms
        self.source = source
        self.scope = scope
        self.partCount = spec.partCount
        self.format = spec.format
        self.unknownFormat = spec.unknownFormat
    }

    /// The part of the file that `dealNumber` receives, or nil when the spec
    /// is not a partition or no number is dealt. A job with no student has no
    /// number and gets the whole file. The part is the number modulo the part
    /// count, so a later change of the count still gives each part to the
    /// same share of the class.
    public func part(forDeal dealNumber: Int?) -> Int? {
        guard kind == .partition, capabilities.partition, let partCount, partCount > 0, let dealNumber,
            dealNumber >= 0
        else {
            return nil
        }
        return dealNumber % partCount
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
        if isShared { return nil }
        return DatasetSpec(rebuilding: self, source: nil, scope: .assignment)
    }

    /// The same spec with another scope. The library attach path is the only
    /// caller that changes a scope.
    public func withScope(_ scope: DatasetSliceScope) -> DatasetSpec {
        DatasetSpec(rebuilding: self, source: source, scope: scope)
    }

    /// True when every student receives the same bytes: no sample, no
    /// transforms and no partition. The "shared" mode of
    /// docs/datasets-course-library.md §4.11, and the only mode an activity
    /// that compares students accepts.
    /// The rule itself is `DatasetDeliveryMode.init`, so this and the editor
    /// working copy's storage form cannot disagree.
    public var isShared: Bool { deliveryMode == .shared }

    private enum CodingKeys: String, CodingKey {
        case file, kind, sampleSize, stratumColumn, transforms, source, scope, partCount, format
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
        partCount = try c.decodeIfPresent(Int.self, forKey: .partCount)
        // A value this server does not know is kept, not refused: the spec
        // must still decode on an older server (docs/dataset-kinds-plan.md §5).
        let rawFormat = try c.decodeIfPresent(String.self, forKey: .format)
        let known = rawFormat.flatMap(DatasetFormat.init(rawValue:))
        format = known ?? .csv
        unknownFormat = known == nil ? rawFormat : nil
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
        try c.encodeIfPresent(partCount, forKey: .partCount)
        if let unknownFormat {
            try c.encode(unknownFormat, forKey: .format)
        } else if format != .csv {
            try c.encode(format, forKey: .format)
        }
    }
}
