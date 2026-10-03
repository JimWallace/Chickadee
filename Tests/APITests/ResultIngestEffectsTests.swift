// Tests/APITests/ResultIngestEffectsTests.swift
//
// `ResultIngestEffects` is the one place a stored result's side effects are
// applied, for the worker report and the browser result alike (#1708). These
// tests pin its gates (a passing build, a student's own submission, 100% for
// the class records) and that the worker report reaches it.
// `BrowserResultSideEffectOrderTests` pins the ordering and the best-effort
// wrapper; `BrowserRunnerRoutesTests` pins the browser route's awards.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized)
struct ResultIngestEffectsTests {

    private static let workerSecret = "ingest-effects-secret"

    private func collection(
        _ submissionID: String, setupID: String, build: BuildStatus = .passed, passed: Bool = true
    ) -> TestOutcomeCollection {
        let outcomes = build == .failed ? [] : [wrMakeOutcome(name: "t1", status: passed ? .pass : .fail)]
        return TestOutcomeCollection(
            submissionID: submissionID, testSetupID: setupID, attemptNumber: 1, buildStatus: build,
            compilerOutput: nil, outcomes: outcomes, totalTests: outcomes.count,
            passCount: passed ? outcomes.count : 0, failCount: passed ? 0 : outcomes.count,
            errorCount: 0, timeoutCount: 0, executionTimeMs: 50, runnerVersion: "test", timestamp: Date())
    }

    /// A setup in the test course and an enrolled student with one submission.
    private func fixture(
        _ prefix: String, on app: Application
    ) async throws -> (setupID: String, submission: APISubmission) {
        let setupID = "\(prefix)_setup"
        _ = try await arInsertSetup(id: setupID, on: app)
        let student = try await arInsertStudent(username: "\(prefix)_student", on: app)
        try await arEnrollStudentInTestCourse(student, on: app)
        let submission = try await arInsertSubmission(
            id: "\(prefix)_sub", testSetupID: setupID, userID: try student.requireID(), on: app)
        return (setupID, submission)
    }

    private func awards(_ setupID: String, on app: Application) async throws -> Set<String> {
        Set(
            try await APIClassAchievement.query(on: app.db).filter(\.$testSetupID == setupID).all()
                .map(\.achievementID))
    }

    private func effects(_ app: Application) -> ResultIngestEffects {
        ResultIngestEffects(application: app, db: app.db, logger: app.logger)
    }

    @Test func aStudentsPassingResultEarnsTheClassRecords() async throws {
        try await withAssignmentRoutesApp { app in
            let (setupID, submission) = try await fixture("rie_pass", on: app)
            await effects(app).apply(
                submission: submission, collection: collection(try submission.requireID(), setupID: setupID))
            #expect(try await awards(setupID, on: app).contains("trailblazer"))
        }
    }

    /// A failed build earns nothing, and neither does a result below 100%,
    /// for the class records.
    @Test func aFailedBuildOrAPartialGradeEarnsNoRecord() async throws {
        try await withAssignmentRoutesApp { app in
            let (setupID, submission) = try await fixture("rie_fail", on: app)
            let id = try submission.requireID()
            await effects(app).apply(
                submission: submission, collection: collection(id, setupID: setupID, build: .failed))
            await effects(app).apply(
                submission: submission, collection: collection(id, setupID: setupID, passed: false))
            #expect(try await awards(setupID, on: app).isEmpty)
        }
    }

    /// A validation run is the instructor's solution, not a student's work.
    @Test func aValidationRunEarnsNothing() async throws {
        try await withAssignmentRoutesApp { app in
            let (setupID, submission) = try await fixture("rie_val", on: app)
            submission.kind = APISubmission.Kind.validation
            try await submission.save(on: app.db)
            await effects(app).apply(
                submission: submission, collection: collection(try submission.requireID(), setupID: setupID))
            #expect(try await awards(setupID, on: app).isEmpty)
        }
    }

    /// The worker report reaches the same service, so a 100% graded by a
    /// runner earns what a 100% graded in the browser earns.
    @Test func theWorkerReportAppliesTheSameEffects() async throws {
        try await withAssignmentRoutesApp { app in
            app.workerSecretStore = WorkerSecretStore(initialOverride: Self.workerSecret)
            let (setupID, submission) = try await fixture("rie_worker", on: app)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let body = ByteBuffer(
                data: try encoder.encode(
                    WorkerExecutionReport(
                        collection: collection(try submission.requireID(), setupID: setupID), diagnostics: nil)))
            let path = "/api/v1/worker/results"
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHMACHeaders(
                        method: .POST, path: path, body: body, workerSecret: Self.workerSecret)
                    req.body = body
                },
                afterResponse: { res in #expect(res.status == .ok) })
            #expect(try await awards(setupID, on: app).contains("trailblazer"))
        }
    }
}
