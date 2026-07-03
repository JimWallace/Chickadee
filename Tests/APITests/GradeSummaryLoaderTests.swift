// Tests/APITests/GradeSummaryLoaderTests.swift
//
// #1157: the blob-free grade loader must agree exactly with the full-row
// loader's folds — including for legacy rows whose denormalized grade
// columns are all nil and whose grade only exists inside collection_json.

import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized) final class GradeSummaryLoaderTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-gradesum")
    }

    private func seedSubmission(id: String) async throws {
        let setupID = "setup_gradesum"
        if try await APITestSetup.find(setupID, on: app.db) == nil {
            let courseID = try await app.testCourseID()
            let setup = APITestSetup(
                id: setupID,
                manifest:
                    #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"tests.py"}],"timeLimitSeconds":10,"makefile":null}"#,
                zipPath: app.testSetupsDirectory + "\(setupID).zip",
                courseID: courseID
            )
            try await setup.save(on: app.db)
        }
        let sub = APISubmission(
            id: id,
            testSetupID: setupID,
            zipPath: app.submissionsDirectory + "\(id).zip",
            attemptNumber: 1,
            status: SubmissionStatus.complete.rawValue
        )
        try await sub.save(on: app.db)
    }

    private func collectionJSON(pass: Int, total: Int) -> String {
        """
        {"submissionID":"x","testSetupID":"setup_gradesum","attemptNumber":1,\
        "buildStatus":"passed","outcomes":[],"totalTests":\(total),"passCount":\(pass),\
        "failCount":\(total - pass),"errorCount":0,"timeoutCount":0,"executionTimeMs":10,\
        "runnerVersion":"shell-runner/1.0","timestamp":"2026-01-01T00:00:00Z"}
        """
    }

    @Test func summariesMatchFullRowFolds() async throws {
        try await withApp(app) { _ in
            try await seedSubmission(id: "sub_gs1")
            // Two results: browser 100 %, then a lower worker regrade.
            try await APIResult(
                id: "res_gs1a", submissionID: "sub_gs1",
                collectionJSON: collectionJSON(pass: 4, total: 4), source: "browser"
            ).save(on: app.db)
            try await APIResult(
                id: "res_gs1b", submissionID: "sub_gs1",
                collectionJSON: collectionJSON(pass: 3, total: 4), source: "worker"
            ).save(on: app.db)

            let viaSummaries = try await bestGradePercentBySubmissionID(
                for: ["sub_gs1"], on: app.db)
            let viaFullRows = try await allResultsBySubmissionID(for: ["sub_gs1"], on: app.db)
                .compactMapValues { bestGradePercent(of: $0) }

            #expect(viaSummaries["sub_gs1"] == 100)
            #expect(viaSummaries == viaFullRows)
        }
    }

    /// A row whose four grade columns are all nil but whose blob carries a
    /// grade (the pre-backfill shape) must still contribute its percent.
    @Test func legacyColumnlessRowFallsBackToBlob() async throws {
        try await withApp(app) { _ in
            try await seedSubmission(id: "sub_gs2")
            let result = APIResult(
                id: "res_gs2", submissionID: "sub_gs2",
                collectionJSON: collectionJSON(pass: 1, total: 2), source: "worker")
            // Simulate the legacy shape: columns never populated.
            result.earnedPoints = nil
            result.totalPoints = nil
            result.passCount = nil
            result.totalTests = nil
            try await result.save(on: app.db)

            let viaSummaries = try await bestGradePercentBySubmissionID(
                for: ["sub_gs2"], on: app.db)
            #expect(viaSummaries["sub_gs2"] == 50)
        }
    }

    @Test func summariesCarryExactPointsForTheBrightSpaceFold() async throws {
        try await withApp(app) { _ in
            try await seedSubmission(id: "sub_gs3")
            let json = """
                {"submissionID":"x","testSetupID":"setup_gradesum","attemptNumber":1,\
                "buildStatus":"passed","outcomes":[],"totalTests":7,"passCount":6,\
                "failCount":1,"errorCount":0,"timeoutCount":0,"executionTimeMs":10,\
                "totalPoints":7,"earnedPoints":6.0,\
                "runnerVersion":"shell-runner/1.0","timestamp":"2026-01-01T00:00:00Z"}
                """
            try await APIResult(
                id: "res_gs3", submissionID: "sub_gs3",
                collectionJSON: json, source: "worker"
            ).save(on: app.db)

            let summaries = try await gradeSummariesBySubmissionID(for: ["sub_gs3"], on: app.db)
            let best = try #require(bestGradeResult(of: Array(summaries.values.joined())))
            // Exact points, not the lossy 86 % round-trip.
            #expect(best.gradePointsValue == 6.0)
            #expect(best.gradeTotalPointsValue == 7.0)
        }
    }
}
