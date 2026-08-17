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
/// them, which is what the Files panel renders its controls from, plus the
/// per-file estimates its disclosure shows.  Serving the estimates on the
/// same response is what makes them live: every parameter edit is a PUT, so
/// the numbers move with the controls without a second request.
struct DatasetsResponse: Content {
    var datasets: [DatasetSpec]
    var diagnostics: [DatasetFileDiagnostics]
}

/// One dataset's estimate block: closed-form overlap (can students copy?)
/// and measured divergence headlines (are they doing the same exercise?).
/// Both computed by Core's `DatasetDiagnostics` from the spec and the
/// bundled file — estimates about the delivered bytes, never a change to
/// them.  See docs/datasets.md.
struct DatasetFileDiagnostics: Content {
    var file: String
    var overlap: DatasetOverlap
    /// The worst column per measure (SDs of transport for numeric columns,
    /// total variation for categorical).  Empty when nothing was measurable.
    var headlines: [DatasetDivergenceHeadline]
    /// False when the file was over the sampling ceiling, so only the
    /// closed-form overlap is reported — stated rather than silently capped.
    var divergenceMeasured: Bool
    /// The class size the worst-pair estimate assumes, so the panel can say
    /// it instead of implying a measured class.
    var classSize: Int
}

/// Files above this size skip the divergence measurement — it materializes
/// the pool once per preflight seed, and the panel is a live control, not a
/// batch job.  Overlap is a single pass and is always reported.
private let datasetDivergenceByteCeiling = 4 << 20

/// The estimate blocks for every spec whose source file can be read as text.
/// A file that cannot be read (or has no data rows) simply has no block —
/// the panel hides the disclosure rather than showing an empty one.
///
/// CPU-bound (the divergence half materializes the pool `defaultSeedCount`
/// times), so handlers call it through `runBlocking` rather than on the
/// event loop.
func datasetDiagnosticsReports(
    zipPath: String, datasets: [DatasetSpec]
) -> [DatasetFileDiagnostics] {
    datasets.compactMap { spec in
        guard let data = extractZipEntry(zipPath: zipPath, entryName: spec.file),
            let text = String(data: data, encoding: .utf8),
            let overlap = DatasetDiagnostics.overlap(spec: spec, sourceCSV: text)
        else { return nil }
        let measurable = data.count <= datasetDivergenceByteCeiling
        let headlines =
            measurable
            ? DatasetDiagnostics.headlines(
                of: DatasetDiagnostics.divergence(spec: spec, sourceCSV: text))
            : []
        return DatasetFileDiagnostics(
            file: spec.file, overlap: overlap, headlines: headlines,
            divergenceMeasured: measurable, classSize: DatasetDiagnostics.defaultClassSize)
    }
}

/// The full panel payload for a setup: its specs plus their estimate blocks,
/// computed off the event loop.  The one constructor every datasets handler
/// uses, so the GET and PUT of both pairs cannot disagree about what the
/// panel is told.
func datasetsPanelResponse(req: Request, setup: APITestSetup) async throws -> DatasetsResponse {
    let specs = datasetSpecs(inManifest: setup.manifest)
    guard !specs.isEmpty else { return DatasetsResponse(datasets: [], diagnostics: []) }
    let zipPath = setup.zipPath
    let diagnostics = try await runBlocking(on: req) {
        datasetDiagnosticsReports(zipPath: zipPath, datasets: specs)
    }
    return DatasetsResponse(datasets: specs, diagnostics: diagnostics)
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
///   - a stratified spec that does not fit its file (`DatasetSpecValidation`):
///     no column named, a column the file does not have, or a sample too small
///     to hold one row of every category. The materializer degrades quietly on
///     all three at delivery time, which is only safe because this refuses them
///     while an instructor is still holding the form.
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
        // Reads the file only when a spec claims something CHECKABLE against it
        // — a stratum column or a transform's columns. An ordinary row sample
        // needs nothing from the bytes, and these files are course datasets, not
        // small. The transform arm matters as much as the stratum one: a
        // transform naming a column the file does not have is absorbed silently
        // at delivery, so this is the only place it can be reported.
        if spec.kind == .stratifiedSample || spec.stratumColumn != nil || !spec.transforms.isEmpty {
            let text = extractZipEntry(zipPath: setup.zipPath, entryName: spec.file)
                .flatMap { String(data: $0, encoding: .utf8) }
            if let issue = DatasetSpecValidation.issue(with: spec, sourceCSV: text) {
                throw Abort(.badRequest, reason: issue)
            }
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
