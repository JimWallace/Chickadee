// Core/DatasetResolver.swift
//
// Resolves a submission's per-student dataset slices (Phase 1 datasets — see
// docs/datasets.md).  For each dataset declared in the manifest it reads the
// instructor's source pool from `sourceDirectory` and returns the student's
// deterministic slice keyed by the delivered filename.
//
// Resolution is server-side and pure given the files on disk plus the seed
// (slicing is delegated to `DatasetMaterializer`), so the worker job payload
// and the browser seed endpoint produce identical bytes for the same student.
// It is a strict no-op — returning nil before any I/O — when the manifest
// declares no datasets, so every non-dataset assignment is entirely unaffected.

import Foundation

public enum DatasetResolver {

    /// Per-student dataset files for `seedHex`, keyed by delivered filename, or
    /// nil when there are no datasets, no seed, or no source file could be read.
    ///
    /// A missing/unreadable source pool for one dataset is skipped (grading then
    /// falls back to the file as shipped) rather than failing resolution for the
    /// whole submission.
    public static func resolve(
        manifest: TestProperties, seedHex: String?, sourceDirectory: String
    ) -> [String: String]? {
        guard !manifest.datasets.isEmpty else { return nil }
        guard let seedHex, !seedHex.isEmpty else { return nil }

        let directory = sourceDirectory.hasSuffix("/") ? sourceDirectory : sourceDirectory + "/"
        var files: [String: String] = [:]
        for spec in manifest.datasets {
            // Defense-in-depth (#1104): a dataset source is by definition a
            // bundled support file at the setup root, so only a bare filename
            // is valid here. A path-carrying spec (e.g. "../../.worker-secret")
            // must not read outside the setup directory; `putDatasets` rejects
            // such specs at authoring time, this guard covers manifests that
            // arrived by other routes (bundle import, hand-edited zip).
            guard FilenameSafety.bareFilename(spec.file) != nil else { continue }
            let path = directory + spec.file
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            files[spec.file] = DatasetMaterializer.materialize(
                source: content, spec: spec, seedHex: seedHex)
        }
        return files.isEmpty ? nil : files
    }
}
