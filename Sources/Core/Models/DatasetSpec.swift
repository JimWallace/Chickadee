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
public enum DatasetKind: String, Codable, Sendable, Equatable {
    case rowSample
}

/// Marks one bundled support file as a per-student dataset.
public struct DatasetSpec: Codable, Equatable, Sendable {
    /// The support filename that is a per-student dataset.  This is both the
    /// source's name in the test setup zip and the name the student sees; the
    /// per-student slice is delivered under this same name.
    public let file: String
    public let kind: DatasetKind
    /// Rows per student for `.rowSample`.  `nil` (or a value ≥ the row count)
    /// means "the whole file" — every student gets the full source.
    public let sampleSize: Int?

    public init(file: String, kind: DatasetKind = .rowSample, sampleSize: Int? = nil) {
        self.file = file
        self.kind = kind
        self.sampleSize = sampleSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        kind = try c.decodeIfPresent(DatasetKind.self, forKey: .kind) ?? .rowSample
        sampleSize = try c.decodeIfPresent(Int.self, forKey: .sampleSize)
    }
}
