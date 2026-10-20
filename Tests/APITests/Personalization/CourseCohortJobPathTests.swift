// Tests/APITests/Personalization/CourseCohortJobPathTests.swift
//
// The course cohort on the worker's job paths
// (docs/datasets-course-library.md, slices 4 and 11): a student's own job
// grades the student's cohort rows; a job with no student grades the pool and
// issues no course seed; and a spare's materialization pins the student's own
// course seed beside the assignment seed.

import Core
import Fluent
import Foundation
import NIOCore
import NIOFoundationCompat
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class CourseCohortJobPathTests {

    let app: Application
    private let workerSecret = "cohort-path-secret"

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-cohort-paths")
        app.workerSecretStore = WorkerSecretStore(initialOverride: workerSecret)
    }

    private let poolCSV = "id,ward\n" + (1...40).map { "\($0),W\($0)" }.joined(separator: "\n") + "\n"
    private let spec = DatasetSpec(
        file: "cases.csv", sampleSize: 5, source: DatasetSource(slug: "cases", version: 1), scope: .course)

    private struct Fixture {
        let courseID: UUID
        let studentID: UUID
        let setupID: String
    }

    private func fixture(_ tag: String) async throws -> Fixture {
        var props = TestProperties(language: nil, datasets: [spec])
        props.gradingMode = .worker
        props.testSuites = [TestSuiteEntry(tier: .pub, script: "tests.py")]
        let setupID = "cpsetup_\(tag)"
        let scenario = try await TestScenario.make(
            on: app, code: "CP\(tag)", setupID: setupID, manifest: try encodeManifest(props), title: "Cohort lab")
        let studentID = try await scenario.enroll("cp_student_\(tag)", on: app)
        let sharedDir = app.testSetupsDirectory + "shared/\(setupID)/"
        try FileManager.default.createDirectory(atPath: sharedDir, withIntermediateDirectories: true)
        try poolCSV.write(toFile: sharedDir + "cases.csv", atomically: true, encoding: .utf8)
        return Fixture(courseID: scenario.courseID, studentID: studentID, setupID: setupID)
    }

    private func submission(_ fx: Fixture, userID: UUID?, kind: String) async throws -> APISubmission {
        let id = "cpsub_\(UUID().uuidString.prefix(8))"
        let path = app.submissionsDirectory + id + ".py"
        try Data("print(1)\n".utf8).write(to: URL(fileURLWithPath: path))
        let row = APISubmission(
            id: id, testSetupID: fx.setupID, zipPath: path, attemptNumber: 1, filename: "main.py", userID: userID,
            kind: kind)
        try await row.save(on: app.db)
        return row
    }

    private func claim() async throws -> Job? {
        let path = "/api/v1/worker/request"
        let body = try ByteBuffer(
            data: JSONEncoder().encode(
                WorkerActivityPayload(
                    workerID: "cp-worker", hostname: "cp.local", runnerVersion: "runner-tests/1.0",
                    maxConcurrentJobs: 1, activeJobs: 0, profile: nil)))
        var job: Job?
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers = workerHMACHeaders(method: .POST, path: path, body: body, workerSecret: self.workerSecret)
                req.body = body
            },
            afterResponse: { res in
                if res.status == .ok { job = try? res.content.decode(Job.self) }
            })
        return job
    }

    private func courseSeedRows(_ courseID: UUID) async throws -> [APICoursePersonalizationSeed] {
        try await APICoursePersonalizationSeed.query(on: app.db).filter(\.$courseID == courseID).all()
    }

    @Test func aStudentsJobGradesTheStudentsCohortRows() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("s")
            let row = try await submission(fx, userID: fx.studentID, kind: APISubmission.Kind.student)
            let job = try #require(try await claim())
            #expect(job.submissionID == row.id)
            let seed = try #require(try await courseSeedRows(fx.courseID).first?.seedValue)
            let expected = DatasetMaterializer.materialize(
                source: poolCSV, spec: spec,
                seedHex: DatasetSeedDerivation.courseScopedSeed(courseSeedHex: seed, slug: "cases"))
            #expect(job.personalizedFiles?["cases.csv"] == expected)
        }
    }

    @Test func aJobWithNoStudentIssuesNoCourseSeed() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("o")
            let row = try await submission(fx, userID: nil, kind: APISubmission.Kind.classAggregate)
            let job = try #require(try await claim())
            #expect(job.submissionID == row.id)
            #expect(job.personalizedFiles == nil)
            #expect(try await courseSeedRows(fx.courseID).isEmpty)
        }
    }

    @Test func aSparePinsTheStudentsCourseSeed() async throws {
        try await withApp(app) { app in
            let fx = try await fixture("p")
            let row = try await submission(fx, userID: nil, kind: APISubmission.Kind.compositeSpare)
            let assignmentSeed = String(repeating: "ab", count: 32)
            let courseSeed = String(repeating: "cd", count: 32)
            _ = await materializeValidationGrading(
                submission: row, setupID: fx.setupID, templateNotebookData: Data(),
                testSetupsDirectory: app.testSetupsDirectory, app: app, on: app.db,
                variantSeedHex: assignmentSeed, variantCourseSeedHex: courseSeed)
            let materialization = try #require(row.decodedMaterialization())
            #expect(materialization.seedHex == assignmentSeed)
            #expect(materialization.courseSeedHex == courseSeed)
        }
    }
}
