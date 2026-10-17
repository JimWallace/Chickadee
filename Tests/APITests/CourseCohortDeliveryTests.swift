// Tests/APITests/CourseCohortDeliveryTests.swift
//
// The course cohort reaches every delivery path
// (docs/datasets-course-library.md, slice 4). A course-scoped dataset gives
// one student the same rows in every assignment of the course, in the editor
// and on the worker; a solution variant grades one synthetic student whose
// course seed is the variant seed; and the editor copy is made again when any
// field of a spec changes.

import Core
import Fluent
import Foundation
import NIOCore
import NIOFoundationCompat
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class CourseCohortDeliveryTests {

    let app: Application
    private let workerSecret = "cohort-worker-secret"

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-cohort")
        app.workerSecretStore = WorkerSecretStore(initialOverride: workerSecret)
    }

    private let poolCSV =
        "id,ward\n" + (1...40).map { "\($0),\($0.isMultiple(of: 2) ? "A" : "B")" }.joined(separator: "\n") + "\n"
    private let slug = "vitaldb-cases"

    private func courseSpec(_ sampleSize: Int = 5, stratum: String? = nil) -> DatasetSpec {
        DatasetSpec(
            file: "cases.csv", kind: stratum == nil ? .rowSample : .stratifiedSample, sampleSize: sampleSize,
            stratumColumn: stratum, source: DatasetSource(slug: slug, version: 1), scope: .course)
    }

    private func manifest(_ spec: DatasetSpec) throws -> String {
        var props = TestProperties(language: nil, datasets: [spec])
        props.gradingMode = .worker
        props.testSuites = [TestSuiteEntry(tier: .pub, script: "tests.py")]
        return try encodeManifest(props)
    }

    private struct Fixture {
        let courseID: UUID
        let instructorID: UUID
        let studentID: UUID
        let setupIDs: [String]
    }

    /// A course with an instructor, a student and two worker-graded
    /// assignments whose shared directories hold the pool.
    private func fixture(_ tag: String, spec: DatasetSpec? = nil) async throws -> Fixture {
        let courseID = try await makeTestCourse(on: app, code: "CC\(tag)").requireID()
        let instructor = try await makeTestUser(on: app, username: "cc_inst_\(tag)", role: "instructor")
        try await makeTestEnrollment(on: app, userID: instructor.requireID(), courseID: courseID)
        let student = try await makeTestUser(on: app, username: "cc_student_\(tag)", role: "student")
        try await makeTestEnrollment(on: app, userID: student.requireID(), courseID: courseID)

        var setupIDs: [String] = []
        for index in 1...2 {
            let setupID = "ccsetup_\(tag)_\(index)"
            try await makeTestSetup(
                on: app, id: setupID, courseID: courseID, manifest: try manifest(spec ?? courseSpec()))
            let sharedDir = app.testSetupsDirectory + "shared/\(setupID)/"
            try FileManager.default.createDirectory(atPath: sharedDir, withIntermediateDirectories: true)
            try poolCSV.write(toFile: sharedDir + "cases.csv", atomically: true, encoding: .utf8)
            _ = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID, title: "Lab \(index)")
            setupIDs.append(setupID)
        }
        return Fixture(
            courseID: courseID, instructorID: try instructor.requireID(), studentID: try student.requireID(),
            setupIDs: setupIDs)
    }

    private func courseSeed(_ userID: UUID, _ courseID: UUID) async throws -> String? {
        try await APICoursePersonalizationSeed.query(on: app.db)
            .filter(\.$userID == userID).filter(\.$courseID == courseID).first()?.seedValue
    }

    private func expectedSlice(courseSeed: String, spec: DatasetSpec? = nil) -> String {
        DatasetMaterializer.materialize(
            source: poolCSV, spec: spec ?? courseSpec(),
            seedHex: DatasetSeedDerivation.courseScopedSeed(courseSeedHex: courseSeed, slug: slug))
    }

    private func editorCopy(_ fx: Fixture, setupIndex: Int) async throws -> String {
        let setup = try #require(try await APITestSetup.find(fx.setupIDs[setupIndex], on: app.db))
        let studentDir = app.testSetupsDirectory + "editor-\(fx.setupIDs[setupIndex])"
        try FileManager.default.createDirectory(atPath: studentDir, withIntermediateDirectories: true)
        await writeDatasetFiles(
            setup: setup, userID: fx.studentID, studentDir: studentDir, on: app.db, application: app)
        return try String(contentsOfFile: studentDir + "/cases.csv", encoding: .utf8)
    }

    // MARK: - The seed store

    @Test func theStoreIssuesOneSeedPerStudentAndCourse() async throws {
        try await withApp(app) { app in
            let fx = try await fixture("s")
            let first = try await CourseSeedStore.ensureSeed(userID: fx.studentID, courseID: fx.courseID, on: app.db)
            let second = try await CourseSeedStore.ensureSeed(userID: fx.studentID, courseID: fx.courseID, on: app.db)
            #expect(first == second)
            #expect(first.count == 64)
        }
    }

    @Test func anAssignmentScopedManifestNeedsNoCourseSeed() async throws {
        try await withApp(app) { app in
            let fx = try await fixture("n", spec: DatasetSpec(file: "cases.csv", sampleSize: 5))
            let props = try #require(try await APITestSetup.find(fx.setupIDs[0], on: app.db)?.decodedManifest())
            #expect(
                try await CourseSeedStore.seedIfNeeded(
                    manifest: props, userID: fx.studentID, courseID: fx.courseID, on: app.db) == nil)
            #expect(try await courseSeed(fx.studentID, fx.courseID) == nil)
        }
    }

    // MARK: - The editor

    @Test func theEditorGivesTheSameRowsInEveryAssignment() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("e")
            let lab = try await editorCopy(fx, setupIndex: 0)
            let report = try await editorCopy(fx, setupIndex: 1)
            #expect(lab == report)
            let seed = try #require(try await courseSeed(fx.studentID, fx.courseID))
            #expect(lab == expectedSlice(courseSeed: seed))
        }
    }

    /// The fingerprint folds the whole spec, so a stratum edit makes a fresh
    /// copy rather than leaving the old rows in place.
    @Test func theEditorCopyFollowsAStratumEdit() async throws {
        try await withApp(app) { app in
            let fx = try await fixture("f")
            let before = try await editorCopy(fx, setupIndex: 0)
            let setup = try #require(try await APITestSetup.find(fx.setupIDs[0], on: app.db))
            let stratified = courseSpec(4, stratum: "ward")
            setup.manifest = try manifest(stratified)
            try await setup.save(on: app.db)
            let after = try await editorCopy(fx, setupIndex: 0)
            let seed = try #require(try await courseSeed(fx.studentID, fx.courseID))
            #expect(after == expectedSlice(courseSeed: seed, spec: stratified))
            #expect(after != before)
        }
    }

    // MARK: - The worker

    /// A dataset-only assignment's primary solution run carries no seed and
    /// grades the pool, as before the cohort; the variants are what grade
    /// per-student material (docs/datasets.md, multi-variant validation).
    @Test func aClaimedVariantGradesOneSyntheticStudentsCohort() async throws {
        try await withApp(app) { app in
            let fx = try await fixture("w")
            _ = try await enqueueRunnerValidationSubmission(
                context: makeTestRequest(on: app), setupID: fx.setupIDs[0],
                solutionNotebookData: Data(#"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#.utf8),
                filename: "solution.ipynb", submitterUserID: fx.instructorID)
            let variants = try await ValidationVariant.query(on: app.db)
                .filter(\.$testSetupID == fx.setupIDs[0]).all()
            #expect(!variants.isEmpty)

            var claimed: [String: Job] = [:]
            let path = "/api/v1/worker/request"
            for attempt in 0...variants.count {
                let body = try ByteBuffer(
                    data: JSONEncoder().encode(
                        WorkerActivityPayload(
                            workerID: "cc-worker-\(attempt)", hostname: "cc.local", runnerVersion: "runner-tests/1.0",
                            maxConcurrentJobs: 1, activeJobs: 0, profile: nil)))
                try await app.asyncTest(
                    .POST, path,
                    beforeRequest: { req in
                        req.headers = workerHMACHeaders(
                            method: .POST, path: path, body: body, workerSecret: self.workerSecret)
                        req.body = body
                    },
                    afterResponse: { res in
                        if res.status == .ok, let job = try? res.content.decode(Job.self) {
                            claimed[job.submissionID] = job
                        }
                    })
            }

            for variant in variants {
                let submissionID = try #require(variant.submissionID)
                let job = try #require(claimed[submissionID])
                #expect(job.personalizedFiles?["cases.csv"] == expectedSlice(courseSeed: variant.seedHex))
            }
        }
    }
}
