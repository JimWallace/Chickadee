// Tests/APITests/MCP/AuthoringSnapshotLoadingTests.swift
//
// What `AuthoringSnapshot.load` (`check_assignment`, #2747) puts in the
// snapshot, and the parts it reports as warnings instead of failing. The
// solution run is in `CheckAssignmentToolRunTests`; this suite covers the
// starter-notebook cells, a missing setup zip, the variant batch and the
// per-seed expression evaluations.
//
// The expression tests run a real `python3` subprocess, like the other
// personalization suites.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3))) struct AuthoringSnapshotLoadingTests {

    private typealias Loaded = (snapshot: AuthoringSnapshot, warnings: [String])

    /// Loads the snapshot for the assignment that `seedMCPAssignment` made
    /// on `setupID`.
    private func load(_ app: Application, assignment: APIAssignment) async throws -> Loaded {
        let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
        let manifest = try #require(setup.decodedManifest())
        return await AuthoringSnapshot.load(
            assignment: assignment, setup: setup, manifest: manifest, context: mcpContext(app, scopes: [.read]))
    }

    private func writeNotebook(_ contents: String, for assignment: APIAssignment, _ app: Application) async throws {
        let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
        let path = try #require(setup.notebookPath)
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Starter notebook

    /// Each cell keeps its own index: a code cell holds its source, any other
    /// kind holds nil. Only a code cell's `{{name}}` placeholder is collected:
    /// substitution rewrites code cells alone, so a markdown mention is prose.
    @Test func notebookCellsKeepTheirIndexAndCodePlaceholdersAreCollected() async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(
                on: app, setupID: "snap_cells", manifest: TestManifests.pythonDeclaredEmpty)
            try await writeNotebook(
                #"""
                {"cells":[\#
                {"cell_type":"markdown","metadata":{},"source":["Use {{cap}} rows."]},\#
                {"cell_type":"code","metadata":{},"execution_count":null,"outputs":[],"source":["x = 1\n","y = {{offset}}"]},\#
                {"cell_type":"raw","metadata":{},"source":"raw text"}\#
                ],"metadata":{},"nbformat":4,"nbformat_minor":5}
                """#,
                for: assignment, app)

            let (snapshot, warnings) = try await load(app, assignment: assignment)

            #expect(warnings.isEmpty)
            #expect(snapshot.notebookCodeCells == [nil, "x = 1\ny = {{offset}}", nil])
            #expect(snapshot.placeholderNames == ["offset"])
            #expect(snapshot.setupZipEntries != nil)
            #expect(snapshot.seedEvaluations.isEmpty)
        }
    }

    /// A notebook that is not JSON is a warning. The other parts still load.
    @Test func anUnparseableNotebookIsAWarning() async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(
                on: app, setupID: "snap_badnb", manifest: TestManifests.pythonDeclaredEmpty)
            try await writeNotebook("this is not a notebook", for: assignment, app)

            let (snapshot, warnings) = try await load(app, assignment: assignment)

            #expect(warnings.count == 1)
            #expect(warnings.first?.contains("starter notebook could not be parsed") == true)
            #expect(snapshot.notebookCodeCells.isEmpty)
            #expect(snapshot.setupZipEntries != nil)
        }
    }

    // MARK: - Setup zip

    /// A missing zip is a warning, not an empty file list: an empty list would
    /// report every file the notebook names as missing.
    @Test func aMissingSetupZipIsAWarningAndListsNoEntries() async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(
                on: app, setupID: "snap_nozip", manifest: TestManifests.pythonDeclaredEmpty)
            let setup = try #require(try await APITestSetup.find("snap_nozip", on: app.db))
            try FileManager.default.removeItem(atPath: setup.zipPath)

            let (snapshot, warnings) = try await load(app, assignment: assignment)

            #expect(warnings.contains { $0.contains("test setup's zip could not be found") })
            #expect(snapshot.setupZipEntries == nil)
            #expect(snapshot.wholeFileSamples.isEmpty)
        }
    }

    // MARK: - Variant batch

    private func collectionJSON(submissionID: String, setupID: String) throws -> String {
        let outcome = TestOutcome(
            testName: "test_a", testClass: nil, tier: .pub, status: .fail, shortResult: "wrong",
            longResult: nil, executionTimeMs: 12, memoryUsageBytes: nil, attemptNumber: 1,
            isFirstPassSuccess: false)
        let collection = TestOutcomeCollection(
            submissionID: submissionID, testSetupID: setupID, attemptNumber: 1, buildStatus: .passed,
            compilerOutput: nil, outcomes: [outcome], totalTests: 1, passCount: 0, failCount: 1,
            errorCount: 0, timeoutCount: 0, executionTimeMs: 12, runnerVersion: "shell-runner/1.0",
            timestamp: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try #require(String(data: try encoder.encode(collection), encoding: .utf8))
    }

    /// The batch comes back in variant order. A variant with a validation run
    /// carries its outcomes. A variant with no run, or one whose submission is
    /// a student's, carries none: the student-data wall holds even for a
    /// corrupted variant row.
    @Test func variantRunsLoadInOrderAndOnlyThroughValidationSubmissions() async throws {
        try await withTestApp { app in
            let setupID = "snap_variants"
            let assignment = try await seedMCPAssignment(
                on: app, setupID: setupID, manifest: TestManifests.pythonDeclaredEmpty)
            let tester = try await mcpTestUser(on: app)
            try await makeTestSubmission(
                on: app, id: "sub_var_val", setupID: setupID, userID: tester.requireID(),
                kind: APISubmission.Kind.validation)
            try await makeTestResult(
                on: app, submissionID: "sub_var_val",
                collectionJSON: collectionJSON(submissionID: "sub_var_val", setupID: setupID))
            try await makeTestSubmission(
                on: app, id: "sub_var_student", setupID: setupID, userID: tester.requireID(),
                kind: APISubmission.Kind.student)
            try await makeTestResult(
                on: app, submissionID: "sub_var_student",
                collectionJSON: collectionJSON(submissionID: "sub_var_student", setupID: setupID))

            // Saved out of order, to show the loader sorts.
            let student = ValidationVariant(
                testSetupID: setupID, variantIndex: 2, seedHex: "cc", submissionID: "sub_var_student")
            let pending = ValidationVariant(
                testSetupID: setupID, variantIndex: 1, seedHex: "bb", submissionID: nil)
            let graded = ValidationVariant(
                testSetupID: setupID, variantIndex: 0, seedHex: "aa", submissionID: "sub_var_val")
            graded.status = ValidationVariant.Status.failed
            for variant in [student, pending, graded] { try await variant.save(on: app.db) }
            // Another setup's variant stays out of this batch.
            try await ValidationVariant(
                testSetupID: "snap_other", variantIndex: 0, seedHex: "dd", submissionID: nil
            ).save(on: app.db)

            let (snapshot, warnings) = try await load(app, assignment: assignment)

            #expect(warnings.isEmpty)
            #expect(snapshot.variants.map(\.variantIndex) == [0, 1, 2])
            #expect(snapshot.variants.map(\.seedHex) == ["aa", "bb", "cc"])
            #expect(snapshot.variants.map(\.status) == ["failed", "pending", "pending"])
            let gradedRun = try #require(snapshot.variants.first?.run)
            #expect(gradedRun.submissionID == "sub_var_val")
            #expect(gradedRun.failCount == 1)
            #expect(snapshot.variants[1].run == nil)
            #expect(snapshot.variants[2].run == nil)
        }
    }

    // MARK: - Seed evaluations

    private static let expressionManifest = #"""
        {"schemaVersion":1,"language":"python","languageDeclared":true,"testSuites":[],"timeLimitSeconds":10,\#
        "globalExpressions":[{"name":"offset","expression":"seed % 3"}]}
        """#

    private static let failingExpressionManifest = #"""
        {"schemaVersion":1,"language":"python","languageDeclared":true,"testSuites":[],"timeLimitSeconds":10,\#
        "globalExpressions":[{"name":"broken","expression":"1 / 0"}]}
        """#

    /// One evaluation per validation-variant seed, in seed order, with the
    /// seeds that the variant runs grade.
    @Test func expressionsAreEvaluatedOncePerVariantSeedInOrder() async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(
                on: app, setupID: "snap_seeds", manifest: Self.expressionManifest)

            let (snapshot, _) = try await load(app, assignment: assignment)

            let expectedSeeds = (0..<validationVariantCount).map { DatasetDiagnostics.preflightSeed($0) }
            #expect(snapshot.seedEvaluations.map(\.seedHex) == expectedSeeds)
            #expect(snapshot.seedEvaluations.allSatisfy { $0.error == nil })
        }
    }

    /// An expression that raises is reported for every seed, so the check
    /// that reads the evaluations can name it.
    @Test func aFailingExpressionIsReportedForEverySeed() async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(
                on: app, setupID: "snap_seed_err", manifest: Self.failingExpressionManifest)

            let (snapshot, _) = try await load(app, assignment: assignment)

            #expect(snapshot.seedEvaluations.count == validationVariantCount)
            #expect(snapshot.seedEvaluations.allSatisfy { $0.error != nil })
        }
    }
}
