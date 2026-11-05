// APIServer/MCP/Tools/AuthoringSnapshot+Loading.swift
//
// Loads the `AuthoringSnapshot` that `check_assignment` runs the checks over
// (#2747). Every run is read through `MCPStudentDataBoundary`, so the loader
// reaches the reference-solution, variant and starter runs and never a student
// row. It enqueues nothing.
//
// One part that cannot be read becomes a warning, not a failed call: the checks
// that need it then find nothing, and the others still run. A missing grant for
// the least-privilege MCP role on a validation table is the failure this
// guards (see `get_validation_result`).

import Core
import Fluent
import Foundation
import Vapor

extension AuthoringSnapshot {
    /// The snapshot, and one warning for each part that could not be read.
    static func load(
        assignment: APIAssignment, setup: APITestSetup, manifest: TestProperties, context: ToolContext
    ) async -> (snapshot: AuthoringSnapshot, warnings: [String]) {
        var snapshot = AuthoringSnapshot(manifest: manifest)
        var warnings: [String] = []
        func attempt(_ part: String, _ body: () async throws -> Void) async {
            do {
                try await body()
            } catch {
                let reason = DatabaseErrorDetail.describe(error)
                context.logger.warning("check_assignment could not read \(part): \(reason)")
                warnings.append("The \(part) could not be read, so the checks that need it found nothing. \(reason)")
            }
        }

        await attempt("solution validation run") {
            snapshot.solutionRun = try await solutionRun(for: assignment, on: context.db)
        }
        await attempt("variant batch") {
            snapshot.variants = try await variantRuns(setupID: assignment.testSetupID, on: context.db)
        }
        // The owner pool, as `get_suite` reads it: the row-level security
        // policy shows the MCP role only `validation` submissions. The boundary
        // still filters on `starterValidation`.
        await attempt("starter run") {
            snapshot.starterRun = try await MCPStudentDataBoundary.starterRun(
                setupID: setup.requireID(), on: context.mainDB)
        }
        // Without the notebook the pattern-family refs are still checked.
        var notebook: Data?
        await attempt("starter notebook") { notebook = try await notebookData(for: setup) }
        snapshot.placeholderNames = PersonalizationPlaceholders.used(notebookData: notebook, manifest: manifest)
        if let notebook {
            if let cells = NotebookCellSources.cells(from: notebook) {
                snapshot.notebookCodeCells = cells.map { cell in
                    cell["cell_type"]?.stringValue == "code" ? NotebookCellSources.cellSource(cell) : nil
                }
            } else {
                warnings.append(
                    "The starter notebook could not be parsed, so the checks that read its cells found nothing.")
            }
        }
        // The same cached listing the working-copy pass reads. A missing zip
        // would list as empty, which reads as "no files" and would report every
        // file the notebook names, so it is a warning instead.
        if FileManager.default.fileExists(atPath: setup.zipPath) {
            snapshot.setupZipEntries = await context.request.application.zipEntryListCache.entries(
                zipPath: setup.zipPath)
        } else {
            warnings.append(
                "The test setup's zip could not be found, so the checks that need its file list found nothing.")
        }
        snapshot.seedEvaluations = await seedEvaluations(
            manifest: manifest, setupID: assignment.testSetupID, context: context)
        return (snapshot, warnings)
    }

    private static func solutionRun(
        for assignment: APIAssignment, on db: any Database
    ) async throws -> TestOutcomeCollection? {
        guard let submission = try await MCPStudentDataBoundary.validationSubmission(for: assignment, on: db),
            let result = try await MCPStudentDataBoundary.latestResult(
                forSubmissionID: submission.requireID(), on: db)
        else { return nil }
        return decodedCollection(try await result.loadCollectionJSON(on: db))
    }

    private static func variantRuns(setupID: String, on db: any Database) async throws -> [VariantRun] {
        let batch = try await ValidationVariant.query(on: db)
            .filter(\.$testSetupID == setupID)
            .sort(\.$variantIndex)
            .all()
        var runs: [VariantRun] = []
        for variant in batch {
            var run: TestOutcomeCollection?
            if let result = try await MCPStudentDataBoundary.variantResult(for: variant, on: db) {
                run = decodedCollection(try await result.loadCollectionJSON(on: db))
            }
            runs.append(
                VariantRun(
                    variantIndex: variant.variantIndex, seedHex: variant.seedHex, status: variant.status, run: run))
        }
        return runs
    }

    /// A stored run's collection JSON, decoded. The caller reads the JSON from
    /// a boundary result, so this file never names the result model
    /// (`MCPStudentDataWallTests`).
    private static func decodedCollection(_ json: String?) -> TestOutcomeCollection? {
        guard let json else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TestOutcomeCollection.self, from: Data(json.utf8))
    }

    /// The expressions evaluated for each validation-variant seed, with the
    /// seeds the variant runs grade (`enqueueValidationVariants` and
    /// `resolveAndCacheValidationMaterialization`): a seed stands for one
    /// synthetic student, so it is that student's course seed as well, and
    /// variant `index` holds dealt number `index`, so a partitioned dataset
    /// reads part `index`. Each evaluation is bounded by the evaluator's own
    /// timeout.
    private static func seedEvaluations(
        manifest: TestProperties, setupID: String, context: ToolContext
    ) async -> [SeedEvaluation] {
        guard manifest.hasExpressions else { return [] }
        let supportDir = context.request.application.testSetupsDirectory + "shared/\(setupID)/"
        let language = AssignmentLanguage.resolve(manifest: manifest)
        var evaluations: [SeedEvaluation] = []
        for index in 0..<validationVariantCount {
            let seedHex = DatasetDiagnostics.preflightSeed(index)
            let resolution = await PersonalizationSubstitution.resolve(
                manifest: manifest, seedHex: seedHex,
                courseSeedHex: manifest.hasCourseScopedDatasets ? seedHex : nil,
                dealNumber: manifest.hasPartitionedDatasets ? index : nil,
                supportFilesDirectory: supportDir, language: language)
            evaluations.append(SeedEvaluation(seedHex: seedHex, error: resolution.evaluationError))
        }
        return evaluations
    }
}
