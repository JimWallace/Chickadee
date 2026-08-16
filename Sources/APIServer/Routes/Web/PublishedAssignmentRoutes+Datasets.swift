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
// Validation and the manifest write live in `DatasetEditHelpers.swift`, shared
// with the draft-scoped pair the create page uses.
//
// See docs/datasets.md (Phase 1) for the full design.

import Core
import Fluent
import Foundation
import Vapor

extension PublishedAssignmentRoutes {

    // MARK: - GET /instructor/:assignmentID/datasets

    @Sendable
    func getDatasets(req: Request) async throws -> DatasetsResponse {
        let (_, setup) = try await loadAssignmentAndSetupForStaffRead(req)
        return DatasetsResponse(datasets: datasetSpecs(inManifest: setup.manifest))
    }

    // MARK: - PUT /instructor/:assignmentID/datasets

    @Sendable
    func putDatasets(req: Request) async throws -> DatasetsResponse {
        let (_, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .ta)
        let body = try req.content.decode(DatasetsBody.self)
        try await applyDatasetsEdit(setup: setup, datasets: body.datasets, on: req.db)
        // Read back rather than echoing the request: the response is what the
        // Files panel renders its controls from, so it has to be the state the
        // manifest now holds.
        return DatasetsResponse(datasets: datasetSpecs(inManifest: setup.manifest))
    }
}
