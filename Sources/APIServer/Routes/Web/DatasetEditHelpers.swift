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

/// One dataset's estimate chips: two concise numbers the row shows inline —
/// student-to-student similarity (closed-form overlap) and drift from the
/// pool (measured divergence) — with the how-it-is-measured detail carried
/// in each chip's hover title.  Display strings are built HERE, server-side,
/// so the wording lives in one tested place and the page JS only paints.
/// Computed by Core's `DatasetDiagnostics`; estimates about the delivered
/// bytes, never a change to them.  See docs/datasets.md.
struct DatasetFileDiagnostics: Content {
    var file: String
    /// The whole chip text, e.g. "similarity 8%": the fraction of one
    /// student's rows a peer is expected to also hold.
    var similarityDisplay: String
    var similarityTitle: String
    /// The whole chip text, e.g. "drift 0.04" — the worst column's typical
    /// distance from the pool — or "drift —" when nothing was measurable.
    var driftDisplay: String
    var driftTitle: String
}

/// Files above this size skip the divergence measurement — it materializes
/// the pool once per preflight seed, and the panel is a live control, not a
/// batch job.  Overlap is a single pass and is always reported.
private let datasetDivergenceByteCeiling = 4 << 20

/// The estimate chips for every spec whose source file can be read as text.
/// A file that cannot be read (or has no data rows) simply has no block —
/// the panel hides the chips rather than showing empty ones.
///
/// CPU-bound (the divergence half materializes the pool `defaultSeedCount`
/// times), so handlers call it through `runBlocking` rather than on the
/// event loop.
func datasetDiagnosticsReports(
    zipPath: String, datasets: [DatasetSpec]
) -> [DatasetFileDiagnostics] {
    datasets.compactMap { spec in
        guard let data = extractZipEntry(zipPath: zipPath, entryName: spec.file),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return datasetEstimateSummary(
            for: spec, sourceCSV: text,
            divergenceMeasurable: data.count <= datasetDivergenceByteCeiling)
    }
}

/// Builds one file's two chips from its spec and source text, or nil when
/// the pool has no data rows to estimate.  Pure given its inputs — the
/// zip-reading and the byte ceiling live in `datasetDiagnosticsReports` —
/// so the wording and number formatting are testable on plain strings.
func datasetEstimateSummary(
    for spec: DatasetSpec, sourceCSV: String, divergenceMeasurable: Bool
) -> DatasetFileDiagnostics? {
    guard let overlap = DatasetDiagnostics.overlap(spec: spec, sourceCSV: sourceCSV)
    else { return nil }

    var similarityTitle =
        "Two students share about \(Int(overlap.expectedSharedRows.rounded())) of their "
        + "\(overlap.rowsPerStudent) rows — the expected overlap between independent "
        + "\(overlap.rowsPerStudent)-row samples of the \(overlap.poolRows)-row pool. "
        + "The unluckiest pair in a class of \(DatasetDiagnostics.defaultClassSize) shares "
        + "about \(Int(overlap.worstPairSharedRows.rounded())) rows."
    if let stratum = overlap.mostCopyableStratum {
        similarityTitle +=
            " Most shared category: \"\(stratum.value)\" — every student draws "
            + "\(stratum.rowsPerStudent) of its \(stratum.poolRows) pool rows "
            + "(\(estimatePercentText(stratum.sharedFraction)) shared)."
    }

    let drift = driftChip(for: spec, sourceCSV: sourceCSV, measurable: divergenceMeasurable)
    return DatasetFileDiagnostics(
        file: spec.file,
        similarityDisplay: "similarity \(estimatePercentText(overlap.sharedFraction))",
        similarityTitle: similarityTitle,
        driftDisplay: drift.display,
        driftTitle: drift.title)
}

/// The drift chip: the worst column's *typical* (median-over-variants)
/// normalized distance from the pool, as one number.  The column, the
/// measure and its unit, the unlucky-variant value, and the other measure's
/// worst column (when both kinds exist) all ride the title.
private func driftChip(
    for spec: DatasetSpec, sourceCSV: String, measurable: Bool
) -> (display: String, title: String) {
    guard measurable else {
        return (
            "drift —",
            "Distribution drift was not measured — the file is too large to sample quickly."
        )
    }
    let columns = DatasetDiagnostics.divergence(spec: spec, sourceCSV: sourceCSV)
    guard let worst = columns.max(by: { $0.median < $1.median }) else {
        return ("drift —", "No measurable columns — nothing observed to compare to the pool.")
    }

    var title =
        "How far a student's data drifts from the pool's distribution, measured over "
        + "\(DatasetDiagnostics.defaultSeedCount) sampled variants; 0 means identical. "
        + "Worst column: \"\(worst.column)\" — typically \(estimateUnitsText(worst.median)) "
        + "\(estimateMeasureName(worst.measure)) from the pool, "
        + "\(estimateUnitsText(worst.worst)) on an unlucky variant."
    if let other = columns.filter({ $0.measure != worst.measure })
        .max(by: { $0.median < $1.median })
    {
        title +=
            " Also: \"\(other.column)\" at \(estimateUnitsText(other.median)) "
            + "\(estimateMeasureName(other.measure))."
    }
    return ("drift \(estimateUnitsText(worst.median))", title)
}

/// A fraction as chip-sized percent text: whole percents from 10% up, one
/// decimal below, and a floor marker rather than a misleading "0%".
func estimatePercentText(_ fraction: Double) -> String {
    let percent = fraction * 100
    if percent >= 99.95 { return "100%" }
    if percent >= 10 { return "\(Int(percent.rounded()))%" }
    if percent >= 0.1 { return String(format: "%.1f%%", percent) }
    return "<0.1%"
}

/// A normalized divergence as chip-sized text: two decimals, with a floor
/// marker rather than a "0.00" that would claim identical distributions.
func estimateUnitsText(_ value: Double) -> String {
    value < 0.005 ? "<0.01" : String(format: "%.2f", value)
}

private func estimateMeasureName(_ measure: DatasetColumnDivergence.Measure) -> String {
    switch measure {
    case .wasserstein: return "pool standard deviations (Wasserstein-1)"
    case .totalVariation: return "in total-variation distance (0–1)"
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
