// Tests/APITests/ValidationVariantTests.swift
//
// Multi-variant validation: every validation enqueue on an assignment that
// varies by student also grades the reference solution against
// `validationVariantCount` derived preflight seeds, recorded as
// `ValidationVariant` rows.
//
// The load-bearing fixture is a DATASET-ONLY manifest — `hasPersonalization`
// false, `variesPerStudent` true — because that is exactly the combination
// the single-run validation path skips (`materializeValidationGrading`
// returns early), which used to mean a dataset assignment validated only
// against the instructor's own slice.  What these assert end to end: the
// batch is enqueued with each variant's seed pinned in its materialization,
// a claimed variant job delivers that seed's dataset slice, and the worker's
// result lands on the variant row rather than on the assignment's primary
// status.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized, .timeLimit(.minutes(3))) final class ValidationVariantTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-valvariants")
        app.workerSecretStore = WorkerSecretStore(initialOverride: workerSecret)
    }

    private let workerSecret = "variant-worker-secret"

    /// Dataset-only: nothing to substitute (`hasPersonalization` false), yet
    /// the material varies by seed (`variesPerStudent` true).
    private let datasetManifest = """
        {"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],\
        "testSuites":[{"tier":"public","script":"tests.py"}],"timeLimitSeconds":10,"makefile":null,\
        "datasets":[{"file":"cases.csv","kind":"rowSample","sampleSize":2}]}
        """

    private let plainManifest = """
        {"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],\
        "testSuites":[{"tier":"public","script":"tests.py"}],"timeLimitSeconds":10,"makefile":null}
        """

    private let poolCSV = "id,ward\n1,A\n2,B\n3,A\n4,B\n"

    private let solutionNotebook =
        #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#

    private struct Fixture {
        let setupID: String
        let submitterID: UUID
        let assignmentPublicID: String
    }

    /// Course + instructor + a worker-graded setup whose shared directory
    /// holds the dataset pool, plus the published assignment row.
    private func fixture(_ tag: String, manifest: String? = nil) async throws -> Fixture {
        let course = try await makeTestCourse(on: app, code: "VV\(tag)")
        let courseID = try course.requireID()
        let user = try await makeTestUser(on: app, username: "vv_inst_\(tag)", role: "instructor")
        let userID = try user.requireID()
        try await makeTestEnrollment(on: app, userID: userID, courseID: courseID)

        let setupID = "vvsetup_\(tag)"
        try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: manifest ?? datasetManifest)
        let sharedDir = app.testSetupsDirectory + "shared/\(setupID)/"
        try FileManager.default.createDirectory(
            atPath: sharedDir, withIntermediateDirectories: true)
        try poolCSV.write(toFile: sharedDir + "cases.csv", atomically: true, encoding: .utf8)

        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: "Variant Lab \(tag)")
        return Fixture(
            setupID: setupID, submitterID: userID, assignmentPublicID: assignment.publicID)
    }

    /// Drives the real enqueue door (the one all five validation triggers
    /// call), returning the primary submission's id.
    private func enqueue(_ fx: Fixture) async throws -> String {
        let req = Request(application: app, on: app.eventLoopGroup.any())
        return try await enqueueRunnerValidationSubmission(
            req: req,
            setupID: fx.setupID,
            solutionNotebookData: Data(solutionNotebook.utf8),
            filename: "solution.ipynb",
            submitterUserID: fx.submitterID)
    }

    private func variantRows(_ setupID: String) async throws -> [ValidationVariant] {
        try await ValidationVariant.query(on: app.db)
            .filter(\.$testSetupID == setupID)
            .sort(\.$variantIndex)
            .all()
    }

    // MARK: - Enqueue

    @Test func enqueuePinsAVariantBatchForADatasetOnlyAssignment() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("a")
            let primaryID = try await enqueue(fx)

            let rows = try await variantRows(fx.setupID)
            #expect(rows.count == validationVariantCount)
            for (index, row) in rows.enumerated() {
                #expect(row.variantIndex == index)
                #expect(row.seedHex == DatasetDiagnostics.preflightSeed(index))
                #expect(row.status == ValidationVariant.Status.pending)

                let submissionID = try #require(row.submissionID)
                let submission = try #require(
                    try await APISubmission.find(submissionID, on: app.db))
                #expect(submission.kind == APISubmission.Kind.validation)
                // The whole point: the variant's seed is pinned in its
                // materialization, so `buildJobPayload` resolves the datasets
                // against the variant's seed rather than the submitter's.
                let materialization = try #require(submission.decodedMaterialization())
                #expect(materialization.seedHex == DatasetDiagnostics.preflightSeed(index))
                #expect(
                    materialization.inputs.isEmpty,
                    "dataset-only: the seed is the variant; there are no expression inputs")
            }

            // The primary run keeps its long-standing dataset-only behaviour —
            // un-materialized, graded against the submitter's own seed.
            let primary = try #require(try await APISubmission.find(primaryID, on: app.db))
            #expect(primary.materializationJSON == nil)

            let validations = try await APISubmission.query(on: app.db)
                .filter(\.$testSetupID == fx.setupID)
                .filter(\.$kind == APISubmission.Kind.validation)
                .count()
            #expect(validations == validationVariantCount + 1)
        }
    }

    @Test func reEnqueueReplacesTheBatchAndANonVaryingManifestClearsIt() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("b")
            _ = try await enqueue(fx)
            let firstBatch = try await variantRows(fx.setupID).compactMap(\.submissionID)

            _ = try await enqueue(fx)
            let secondRows = try await variantRows(fx.setupID)
            #expect(secondRows.count == validationVariantCount, "replaced, not appended")
            let secondBatch = Set(secondRows.compactMap(\.submissionID))
            #expect(secondBatch.isDisjoint(with: firstBatch), "a fresh batch of runs")

            // The manifest stops varying: the next enqueue must clear the
            // batch, or a stale verdict keeps describing an assignment that is
            // no longer per-student.
            let setup = try #require(try await APITestSetup.find(fx.setupID, on: app.db))
            setup.manifest = plainManifest
            try await setup.save(on: app.db)
            _ = try await enqueue(fx)
            #expect(try await variantRows(fx.setupID).isEmpty)
        }
    }

    // MARK: - Claim: the variant job delivers the variant's material

    @Test func aClaimedVariantJobCarriesItsSeedAndItsDatasetSlice() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("c")
            _ = try await enqueue(fx)
            let rows = try await variantRows(fx.setupID)
            let seedBySubmission = Dictionary(
                uniqueKeysWithValues: rows.compactMap { row in
                    row.submissionID.map { ($0, row.seedHex) }
                })

            // Claim every pending job (primary + variants); collect the Jobs.
            var claimed: [String: Job] = [:]
            let path = "/api/v1/worker/request"
            for attempt in 0..<(validationVariantCount + 1) {
                let body = try ByteBuffer(
                    data: JSONEncoder().encode(
                        WorkerActivityPayload(
                            workerID: "vv-worker-\(attempt)", hostname: "vv.local",
                            runnerVersion: "runner-tests/1.0", maxConcurrentJobs: 1,
                            activeJobs: 0, profile: nil)))
                try await app.asyncTest(
                    .POST, path,
                    beforeRequest: { req in
                        req.headers = workerHMACHeaders(
                            method: .POST, path: path, body: body, workerSecret: self.workerSecret)
                        req.body = body
                    },
                    afterResponse: { res in
                        #expect(res.status == .ok, "claim \(attempt) — \(res.status)")
                        let job = try res.content.decode(Job.self)
                        claimed[job.submissionID] = job
                    })
            }

            let spec = DatasetSpec(file: "cases.csv", kind: .rowSample, sampleSize: 2)
            for (submissionID, seedHex) in seedBySubmission {
                let job = try #require(claimed[submissionID], "variant \(submissionID) was claimable")
                #expect(job.assignmentSeed == seedHex)
                let files = try #require(job.personalizedFiles)
                #expect(
                    files["cases.csv"]
                        == DatasetMaterializer.materialize(
                            source: poolCSV, spec: spec, seedHex: seedHex),
                    "the job delivers the slice a student holding this seed would get")
            }
        }
    }

    // MARK: - Result ingestion

    @Test func aVariantResultLandsOnTheVariantRowNotTheAssignment() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("d")
            _ = try await enqueue(fx)
            let rows = try await variantRows(fx.setupID)
            let failing = try #require(rows.first?.submissionID)
            let passing = try #require(rows.dropFirst().first?.submissionID)

            try await postResult(submissionID: failing, setupID: fx.setupID, pass: false)
            try await postResult(submissionID: passing, setupID: fx.setupID, pass: true)

            let updated = try await variantRows(fx.setupID)
            #expect(updated.first?.status == ValidationVariant.Status.failed)
            #expect(updated.dropFirst().first?.status == ValidationVariant.Status.passed)
            #expect(
                updated.dropFirst(2).allSatisfy {
                    $0.status == ValidationVariant.Status.pending
                })

            // A variant is never the assignment's linked primary, so the
            // assignment's own validationStatus must not move.
            let assignment = try #require(
                try await APIAssignment.query(on: app.db)
                    .filter(\.$publicID == fx.assignmentPublicID)
                    .first())
            #expect(assignment.validationStatus == nil)
        }
    }

    private func postResult(submissionID: String, setupID: String, pass: Bool) async throws {
        let outcome = TestOutcome(
            testName: "t1", testClass: nil, tier: .pub,
            status: pass ? .pass : .fail,
            shortResult: pass ? "ok" : "wrong answer", longResult: nil,
            executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1,
            isFirstPassSuccess: pass)
        let collection = TestOutcomeCollection(
            submissionID: submissionID, testSetupID: setupID, attemptNumber: 1,
            buildStatus: .passed, compilerOutput: nil, outcomes: [outcome],
            totalTests: 1, passCount: pass ? 1 : 0, failCount: pass ? 0 : 1,
            errorCount: 0, timeoutCount: 0, executionTimeMs: 5,
            runnerVersion: "runner-tests/1.0", timestamp: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try ByteBuffer(data: encoder.encode(collection))
        let path = "/api/v1/worker/results"
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers = workerHMACHeaders(
                    method: .POST, path: path, body: body, workerSecret: self.workerSecret)
                req.body = body
            },
            afterResponse: { res in
                #expect(res.status == .ok, "posting result for \(submissionID)")
            })
    }

}

/// The pure fold-down the listing row renders — no app, so a separate struct
/// suite (the class suite above builds an `Application` per test instance,
/// and a test that skips `withApp` would leak it into a deinit assertion).
@Suite struct ValidationVariantSummaryTests {

    @Test func variantSummaryFoldsTheBatchForTheListingRow() {
        let pendingWins = ValidationVariantSummary(
            total: 4, failed: 1, pending: 2, firstFailedSubmissionID: "sub_x")
        #expect(pendingWins.state == "pending")
        #expect(pendingWins.summaryText == "4 variants running")

        let failed = ValidationVariantSummary(
            total: 4, failed: 2, pending: 0, firstFailedSubmissionID: "sub_x")
        #expect(failed.state == "failed")
        #expect(failed.summaryText == "2 of 4 variants failed")

        let passed = ValidationVariantSummary(
            total: 4, failed: 0, pending: 0, firstFailedSubmissionID: nil)
        #expect(passed.state == "passed")
        #expect(passed.summaryText == "4 variants passed")

        let none = ValidationVariantSummary(
            total: 0, failed: 0, pending: 0, firstFailedSubmissionID: nil)
        #expect(none.state == "none")
        #expect(none.summaryText.isEmpty)
    }
}
