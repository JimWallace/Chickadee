// Core/DatasetWholeFileSample.swift
//
// A sample at or above the file's data-row count gives every student the whole
// file (`DatasetMaterializer.sampleRows` returns the source unchanged), but
// `DatasetDeliveryMode` reads only the spec, so it classifies that sample as
// `perStudent`: each student's editor stores a private copy of the same bytes
// (docs/dataset-shared-delivery.md, "Whole-file samples").
//
// The mode stays spec-only on purpose. This file is the other half: a door
// that saves a library attachment knows the file, so it normalizes such a
// sample away before it stores it, and `check_assignment` reports a stored
// one.

/// Detects and removes a sample that delivers the whole file.
public enum DatasetWholeFileSample {

    /// What a save stores in place of a whole-file sample.
    public enum Normalization: Equatable, Sendable {
        /// The spec does not deliver the whole file through a sample. Store it
        /// as it is.
        case unchanged
        /// Store this spec: the same file and library fields, with no sample.
        /// Its delivery mode is `shared`.
        case shared(DatasetSpec)
    }

    /// The number of data rows in `csv`, counted as the materializer counts
    /// them: every line after the header.
    public static func dataRowCount(of csv: String) -> Int {
        max(DatasetMaterializer.normalizedLines(of: csv).lines.count - 1, 0)
    }

    /// True when `spec` gives every student the whole file through a sample
    /// of at least `dataRowCount` rows, with nothing that varies the bytes per
    /// student. A partition and a transformed spec are never whole-file
    /// samples: a part is a subset, and a transform varies the cells.
    public static func deliversWholeFile(_ spec: DatasetSpec, dataRowCount: Int) -> Bool {
        guard spec.kind != .partition, spec.transforms.isEmpty, let sampleSize = spec.sampleSize else {
            return false
        }
        return sampleSize >= dataRowCount
    }

    /// What to store for `spec` against a file of `dataRowCount` data rows.
    ///
    /// Only a library attachment is normalized: its spec keeps its source, so
    /// a spec with no sample is still a spec. A file not attached from the
    /// library is left as it is. With no sample and no transforms its spec
    /// would do nothing, and dropping the spec would also drop the file from
    /// the submit page's dataset downloads, which is how a student of an
    /// upload-only assignment receives it. `check_assignment` reports it.
    ///
    /// A stratum column goes with the sample: the whole file holds every
    /// category, and validation refuses a column on a spec with no sample.
    public static func normalization(of spec: DatasetSpec, dataRowCount: Int) -> Normalization {
        guard spec.source != nil, deliversWholeFile(spec, dataRowCount: dataRowCount) else { return .unchanged }
        return .shared(
            DatasetSpec(
                file: spec.file, kind: .rowSample, source: spec.source, scope: spec.scope, format: spec.format))
    }
}
