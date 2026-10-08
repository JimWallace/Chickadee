// APIServer/Services/DatasetSpecCheck.swift
//
// The one check for a dataset spec that an authoring door is about to store.
// The web `PUT /datasets` routes and MCP `set_dataset` both call it, so the two
// refuse the same specs (#2487). Before, the web accepted a graded script or a
// notebook as a dataset and a spec with no `sampleSize`, which MCP refused.

import Core
import Foundation

/// The setup zip's entry names, with a leading "./" removed, which is how a
/// dataset spec names its file.
func bundledFileNames(zipPath: String) async -> Set<String> {
    await Set(
        listZipEntries(zipPath: zipPath).map { entry in
            entry.hasPrefix("./") ? String(entry.dropFirst(2)) : entry
        })
}

/// Why `spec` cannot be stored on `setup`, or nil. In the order a caller is
/// likely to hit them:
///   - a `file` that is not a bare filename. The value is joined onto
///     directory paths at read time (`DatasetResolver`) and at delivery time on
///     both the server and the worker, so a separator or traversal component
///     would read outside the setup directory (#1104).
///   - a `file` the setup zip does not bundle. A dataset marks an existing
///     support file as per-student; it never introduces one.
///   - a graded script or a canonical notebook, which is not support data.
///   - no `sampleSize`, or one below 1.
///   - a spec that does not fit its file (`DatasetSpecValidation`): a stratum
///     column the file does not have, a sample too small to hold one row of
///     every category, or a transform that names a missing column. The
///     materializer degrades quietly on each at delivery time, which is only
///     safe because this refuses them while an author can still fix them.
func datasetSpecRefusal(
    _ spec: DatasetSpec, setup: APITestSetup, bundledFiles: Set<String>
) async -> String? {
    guard FilenameSafety.bareFilename(spec.file) == spec.file else {
        return "Dataset file '\(spec.file)' must be a bare filename with no path components."
    }
    guard bundledFiles.contains(spec.file) else {
        return "Dataset file '\(spec.file)' is not among this assignment's bundled files."
    }
    let suiteScripts = Set(setup.decodedManifest()?.testSuites.map(\.script) ?? [])
    guard !suiteScripts.contains(spec.file), spec.file != "assignment.ipynb", spec.file != "solution.ipynb"
    else {
        return "'\(spec.file)' is not a support file. Only a support data file can be a per-student dataset."
    }
    guard let sampleSize = spec.sampleSize, sampleSize >= 1 else {
        return "sampleSize for '\(spec.file)' is required and must be 1 or more."
    }
    // Reads the file only when the spec claims something checkable against
    // it. A plain row sample needs nothing from the bytes, and these files are
    // course datasets, not small.
    guard spec.kind == .stratifiedSample || spec.stratumColumn != nil || !spec.transforms.isEmpty else {
        return nil
    }
    let text = await extractZipEntry(zipPath: setup.zipPath, entryName: spec.file)
        .flatMap { String(data: $0, encoding: .utf8) }
    return DatasetSpecValidation.issue(with: spec, sourceCSV: text)
}

/// Reads the dataset specs off a setup's manifest.  An undecodable manifest
/// reports no datasets rather than failing the read: the panel then shows every
/// support file as unmarked, which is what a manifest carrying no `datasets`
/// key means anyway.
func datasetSpecs(inManifest manifest: String) -> [DatasetSpec] {
    guard let data = manifest.data(using: .utf8),
        let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: data)
    else { return [] }
    return props.datasets
}
