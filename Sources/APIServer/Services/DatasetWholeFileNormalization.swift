// APIServer/Services/DatasetWholeFileNormalization.swift
//
// The save-time half of `DatasetWholeFileSample` (Core): every door that
// stores a library attachment's spec reads the file's row count here and
// stores no sample when the sample would cover the whole file. Without this, a sample of 384
// rows on a 384-row file gives every student a private copy of the same bytes
// (docs/dataset-shared-delivery.md, "Whole-file samples").
//
// Stored manifests are not migrated. A spec is normalized the next time a
// door saves it, and `check_assignment` (`WholeFileSampleCheck`) and the MCP
// dataset tools report one that is still stored. The reports themselves are
// in `Utilities/WholeFileSampleReports.swift`, so the check can build one.

import Core
import Foundation

/// The data-row count of `file` in the setup zip, or nil when the file is
/// missing or is not UTF-8 text.
func bundledDataRowCount(zipPath: String, file: String) async -> Int? {
    guard let data = await extractZipEntry(zipPath: zipPath, entryName: file),
        let text = String(data: data, encoding: .utf8)
    else { return nil }
    return DatasetWholeFileSample.dataRowCount(of: text)
}

/// `spec` as a save stores it, given the file's text, and the report when it
/// changed. A file that is not UTF-8 is left as it is.
func normalizedForSave(
    _ spec: DatasetSpec, sourceCSV: String?
) -> (spec: DatasetSpec, normalization: WholeFileSampleNormalization?) {
    guard let sourceCSV, let sampleSize = spec.sampleSize else { return (spec, nil) }
    let rows = DatasetWholeFileSample.dataRowCount(of: sourceCSV)
    switch DatasetWholeFileSample.normalization(of: spec, dataRowCount: rows) {
    case .unchanged:
        return (spec, nil)
    case .shared(let shared):
        return (shared, WholeFileSampleNormalization(file: spec.file, sampleSize: sampleSize, dataRowCount: rows))
    }
}

/// `spec` as a save stores it, reading the file from the setup zip only when
/// the spec could be normalized.
func normalizedForSave(
    _ spec: DatasetSpec, zipPath: String
) async -> (spec: DatasetSpec, normalization: WholeFileSampleNormalization?) {
    guard spec.source != nil, isWholeFileCandidate(spec) else { return (spec, nil) }
    let text = await extractZipEntry(zipPath: zipPath, entryName: spec.file)
        .flatMap { String(data: $0, encoding: .utf8) }
    return normalizedForSave(spec, sourceCSV: text)
}

/// Every spec in `specs` whose sample covers its whole file, in `specs`
/// order. Reads only the files of specs that could be one.
func wholeFilePerStudentSamples(
    in specs: [DatasetSpec], zipPath: String
) async -> [WholeFilePerStudentSample] {
    var found: [WholeFilePerStudentSample] = []
    for spec in specs where isWholeFileCandidate(spec) {
        guard let sampleSize = spec.sampleSize,
            let rows = await bundledDataRowCount(zipPath: zipPath, file: spec.file),
            DatasetWholeFileSample.deliversWholeFile(spec, dataRowCount: rows)
        else { continue }
        found.append(
            WholeFilePerStudentSample(
                file: spec.file, sampleSize: sampleSize, dataRowCount: rows, isLibraryAttachment: spec.source != nil))
    }
    return found
}

/// True when only the file's row count decides whether `spec` is a
/// whole-file sample. Spares a read of every other file.
private func isWholeFileCandidate(_ spec: DatasetSpec) -> Bool {
    spec.sampleSize != nil && spec.kind != .partition && spec.transforms.isEmpty
}
