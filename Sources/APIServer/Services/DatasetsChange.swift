// APIServer/Services/DatasetsChange.swift
//
// The one dataset-spec edit. The web `PUT /datasets` routes (assignment and
// draft) and MCP `set_dataset` all call `applyDatasetsEdit`, so the three
// refuse the same changes (#2771). Before, MCP ran each step again by hand:
// `datasetSpecRefusal`, the library-attached guard, `ManifestCoherence` and
// `mutateManifest`. Only comments kept the two copies aligned.
//
// See docs/datasets.md for what a spec means at delivery time.

import Core
import Fluent
import Foundation

/// A change to an assignment's dataset specs.
enum DatasetsChange: Sendable {
    /// Replace the whole array. The web routes send the complete desired
    /// state, so every spec in it is checked.
    case replaceAll([DatasetSpec])
    /// Replace the spec for one file, or remove it when the spec is nil. The
    /// other specs stay as they are and are not checked again. MCP
    /// `set_dataset` edits one file at a time.
    case replace(file: String, with: DatasetSpec?)

    /// The specs that this change writes, and so must pass the checks.
    var writtenSpecs: [DatasetSpec] {
        switch self {
        case .replaceAll(let specs): return specs
        case .replace(_, let spec): return spec.map { [$0] } ?? []
        }
    }

    /// `datasets` after the change.
    ///
    /// A one-file change applies to the array that it is given, so a lost
    /// manifest race keeps another edit of a different file (#2019). The
    /// replaced spec moves to the end, and every spec for its file is
    /// removed: two specs for one file would disagree about how many rows a
    /// student gets.
    func applied(to datasets: [DatasetSpec]) -> [DatasetSpec] {
        switch self {
        case .replaceAll(let specs):
            return specs
        case .replace(let file, let spec):
            var result = datasets.filter { $0.file != file }
            if let spec { result.append(spec) }
            return result
        }
    }
}

/// Validates `change` against the setup's bundled files and writes it into
/// the manifest.
///
/// Each written spec must pass `datasetSpecRefusal` and must keep the library
/// fields that the manifest already holds for its file
/// (`DatasetSpecValidation.libraryFieldIssue`). The result must not name one
/// file twice, must not drop the spec of a file attached from the course
/// library, and must not give personal data to an activity that ranks or
/// matches students. Throws `DatasetsEditError` for a refusal.
func applyDatasetsEdit(
    setup: APITestSetup, change: DatasetsChange, on db: any Database
) async throws {
    let current = setup.decodedManifest()?.datasets ?? []
    let stored = setup.decodedManifest()?.datasetSpecsByFile ?? [:]
    let written = change.writtenSpecs

    if !written.isEmpty {
        let bundledFiles = await bundledFileNames(zipPath: setup.zipPath)
        var seenFiles: Set<String> = []
        for spec in written {
            if let refusal = await datasetSpecRefusal(spec, setup: setup, bundledFiles: bundledFiles) {
                throw DatasetsEditError.specRefused(refusal)
            }
            // The library fields are written by the library attach path only;
            // this door carries them through (docs/datasets-course-library.md).
            if let refusal = DatasetSpecValidation.libraryFieldIssue(proposed: spec, stored: stored[spec.file]) {
                throw DatasetsEditError.specRefused(refusal)
            }
            guard seenFiles.insert(spec.file).inserted else {
                throw DatasetsEditError.duplicateFile(spec.file)
            }
        }
    }

    // An attached spec may be edited here but not dropped: dropping it would
    // end the attachment and give every student the whole file. Detach does
    // that deliberately and keeps the sample.
    let resultFiles = Set(change.applied(to: current).map(\.file))
    for (file, spec) in stored.sorted(by: { $0.key < $1.key })
    where spec.source != nil && !resultFiles.contains(file) {
        throw DatasetsEditError.attachedSpecDropped(file)
    }

    // An activity that ranks or matches students refuses personal data.
    if let violation = ManifestCoherence.violation(
        introducedBy: { $0.datasets = change.applied(to: $0.datasets) }, in: setup.manifest)
    {
        throw DatasetsEditError.incoherent(violation)
    }

    try await mutateManifest(setup: setup, on: db) { props in
        props.datasets = change.applied(to: props.datasets)
    }
}
