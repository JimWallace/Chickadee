// APIServer/Routes/Web/PublishedAssignmentRoutes+Datasets.swift
//
// GET/PUT /instructor/:assignmentID/datasets
//
// Reads and writes the per-student dataset specs on an assignment's
// TestProperties. Each spec marks one bundled support file as a per-student
// dataset: the server materializes a deterministic slice from the assignment
// seed and delivers the resulting bytes to grading and the editor under the
// same filename — so the notebook's `pd.read_csv("…")` line is unchanged
// but every student sees their own rows.
//
// See docs/datasets.md (Phase 1) for the full design.

import Core
import Fluent
import Foundation
import Vapor

extension PublishedAssignmentRoutes {

    struct DatasetsBody: Content {
        var datasets: [DatasetSpec]
    }

    struct DatasetsResponse: Content {
        var datasets: [DatasetSpec]
    }

    // MARK: - GET /instructor/:assignmentID/datasets

    @Sendable
    func getDatasets(req: Request) async throws -> DatasetsResponse {
        let (_, setup) = try await loadAssignmentAndSetup(req)
        guard let manifestData = setup.manifest.data(using: .utf8),
            let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: manifestData)
        else {
            return DatasetsResponse(datasets: [])
        }
        return DatasetsResponse(datasets: props.datasets)
    }

    // MARK: - PUT /instructor/:assignmentID/datasets

    @Sendable
    func putDatasets(req: Request) async throws -> DatasetsResponse {
        let (_, setup) = try await loadAssignmentAndSetupForWrite(req)
        let body = try req.content.decode(DatasetsBody.self)

        // Validate: each spec must name a non-empty file; sampleSize if
        // present must be positive.
        for spec in body.datasets {
            guard !spec.file.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw Abort(.badRequest, reason: "Dataset spec has an empty file name.")
            }
            if let n = spec.sampleSize, n <= 0 {
                throw Abort(.badRequest, reason: "sampleSize for '\(spec.file)' must be positive.")
            }
        }

        // Splice the updated datasets array into the manifest JSON, preserving
        // every other field. Using JSONSerialization lets us avoid rebuilding the
        // entire manifest from components (no risk of dropping unrecognised keys).
        guard let manifestData = setup.manifest.data(using: .utf8),
            var dict = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        else {
            throw Abort(.internalServerError, reason: "Could not decode assignment manifest.")
        }

        if body.datasets.isEmpty {
            dict.removeValue(forKey: "datasets")
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(body.datasets)
            if let parsed = try? JSONSerialization.jsonObject(with: encoded) as? [Any] {
                dict["datasets"] = parsed
            }
        }

        let newData = try JSONSerialization.data(withJSONObject: dict)
        guard let newManifest = String(data: newData, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "Could not re-encode assignment manifest.")
        }
        setup.manifest = newManifest
        try await setup.save(on: req.db)

        return DatasetsResponse(datasets: body.datasets)
    }
}
