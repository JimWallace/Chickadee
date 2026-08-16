// APIServer/Routes/Web/DatasetEditHelpers.swift
//
// Shared core for the datasets handlers — both the assignment-scoped pair
// (`/instructor/:assignmentID/datasets`) and the draft-scoped pair the create
// page uses (`/instructor/new/draft/datasets?draftID=<id>`).  Same split as
// `SuiteEditHelpers.swift`: the handlers own auth + setup resolution, this file
// owns validation and the manifest write, so the create page cannot drift into
// accepting a spec the edit page rejects.
//
// See docs/datasets.md (Phase 1) for what a spec means at delivery time.

import Core
import Fluent
import Foundation
import Vapor

/// The request body of either PUT.  The whole array is the payload: a write
/// replaces the assignment's dataset specs, so a caller sends the complete
/// desired state rather than a delta.
struct DatasetsBody: Content {
    var datasets: [DatasetSpec]
}

/// The response of either GET or PUT — the specs as the manifest now holds
/// them, which is what the Files panel renders its controls from.
struct DatasetsResponse: Content {
    var datasets: [DatasetSpec]
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

/// Validates `datasets` against the setup's bundled files and writes the
/// resulting array into the manifest, replacing whatever was there.
///
/// This is a whole-array replace, not a patch — callers send the complete
/// desired state.
///
/// Rejects (`.badRequest`), in the order a caller is likely to hit them:
///   - a `file` that is not a bare filename.  The value is joined onto
///     directory paths at read time (`DatasetResolver`) and at delivery time on
///     both the server and the worker, so a separator or traversal component
///     would read outside the setup directory (#1104).
///   - a `file` the setup zip does not bundle.  A dataset marks an existing
///     support file as per-student; it never introduces one.
///   - a non-positive `sampleSize`.
///   - two specs for the same file, which is incoherent — the two would
///     disagree about how many rows a student gets, and which one wins is a
///     detail of whichever consumer happens to fold the array.
func applyDatasetsEdit(
    setup: APITestSetup, datasets: [DatasetSpec], on db: Database
) async throws {
    let zipEntries = Set(
        listZipEntries(zipPath: setup.zipPath).map { entry in
            entry.hasPrefix("./") ? String(entry.dropFirst(2)) : entry
        })
    var seenFiles: Set<String> = []
    for spec in datasets {
        guard FilenameSafety.bareFilename(spec.file) != nil else {
            throw Abort(
                .badRequest,
                reason: "Dataset file '\(spec.file)' must be a bare filename with no path components.")
        }
        guard zipEntries.contains(spec.file) else {
            throw Abort(
                .badRequest,
                reason: "Dataset file '\(spec.file)' is not among this assignment's bundled files.")
        }
        if let n = spec.sampleSize, n <= 0 {
            throw Abort(.badRequest, reason: "sampleSize for '\(spec.file)' must be positive.")
        }
        guard seenFiles.insert(spec.file).inserted else {
            throw Abort(.badRequest, reason: "Dataset file '\(spec.file)' is listed more than once.")
        }
    }

    // Splice the updated array into the manifest JSON, preserving every other
    // field.  Using JSONSerialization lets us avoid rebuilding the entire
    // manifest from components (no risk of dropping unrecognised keys).
    guard let manifestData = setup.manifest.data(using: .utf8),
        var dict = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
    else {
        throw Abort(.internalServerError, reason: "Could not decode assignment manifest.")
    }

    if datasets.isEmpty {
        dict.removeValue(forKey: "datasets")
    } else {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(datasets)
        if let parsed = try? JSONSerialization.jsonObject(with: encoded) as? [Any] {
            dict["datasets"] = parsed
        }
    }

    let newData = try JSONSerialization.data(withJSONObject: dict)
    guard let newManifest = String(data: newData, encoding: .utf8) else {
        throw Abort(.internalServerError, reason: "Could not re-encode assignment manifest.")
    }
    setup.manifest = newManifest
    try await setup.save(on: db)
}
