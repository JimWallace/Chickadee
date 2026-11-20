// Tests/APITests/Admin/AdminRunnerDetailFallbackTests.swift
//
// The runner detail page (GET /admin/runners/:runnerID) for the cases the
// larger AdminRoutesTests suite does not reach: a runner that the activity
// store has pruned (the page rebuilds the row from the newest snapshot), a
// runner nobody has ever seen (404), a non-admin viewer (403), the time-limit
// note on a timed-out job, the cache hit rate, and the capability tags.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AdminRunnerDetailFallbackTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-runner-detail")
    }

    private func detail(
        _ runnerID: String, cookie: String
    ) async throws -> (status: HTTPStatus, body: String) {
        var status: HTTPStatus = .ok
        var body = ""
        try await app.asyncTest(
            .GET, "/admin/runners/\(runnerID)",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                status = res.status
                body = res.body.string
            })
        return (status, body)
    }

    private func saveSnapshot(runnerID: String, hostname: String, age: TimeInterval) async throws {
        let snapshot = RunnerSnapshot(
            runnerID: runnerID,
            recordedAt: Date().addingTimeInterval(-age),
            activeJobs: 0,
            maxJobs: 3,
            availableCapacity: 3,
            hostname: hostname,
            runnerVersion: "runner/9.9",
            lastPollAt: nil,
            lastHeartbeatAt: nil,
            serverAssignedJobCountSinceStart: nil
        )
        try await snapshot.save(on: app.db)
    }

    /// A finished job on `runnerID`, against a fresh setup whose manifest is
    /// `manifest` (nil keeps the fixture manifest, with a 10 s limit).
    private func saveJob(
        runnerID: String, tag: String, status: String, cacheHit: Bool?, manifest: String? = nil
    ) async throws {
        let course = try await makeTestCourse(on: app, code: "RD\(tag)")
        let courseID = try course.requireID()
        let setupID = "setup_rd_\(tag)"
        if let manifest {
            try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: manifest)
        } else {
            try await makeTestSetup(on: app, id: setupID, courseID: courseID)
        }
        let student = try await makeTestUser(on: app, username: "rd_student_\(tag)")
        let studentID = try student.requireID()
        let submission = try await makeTestSubmission(
            on: app, id: "sub_rd_\(tag)", setupID: setupID, userID: studentID)
        submission.workerID = runnerID
        submission.status = SubmissionStatus.complete.rawValue
        try await submission.update(on: app.db)

        let metric = JobExecutionMetric(
            submissionID: try submission.requireID(),
            jobID: try submission.requireID(),
            testSetupID: setupID,
            courseID: courseID,
            assignmentID: nil,
            userID: studentID,
            runnerID: runnerID,
            kind: APISubmission.Kind.student,
            attemptNumber: 1,
            enqueuedAt: Date().addingTimeInterval(-60)
        )
        metric.completedAt = Date().addingTimeInterval(-30)
        metric.finalStatus = status
        metric.testSetupCacheHit = cacheHit
        try await metric.save(on: app.db)
    }

    // MARK: - Refusals

    @Test func aRunnerWithNoStoreRowAndNoSnapshotIsNotFound() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("runner_detail_admin", on: app)
            let response = try await detail("runner-never-seen", cookie: cookie)
            #expect(response.status == .notFound)
        }
    }

    @Test func aStudentIsRefusedTheRunnerDetailPage() async throws {
        try await withApp(app) { _ in
            try await saveSnapshot(runnerID: "runner-private", hostname: "private-host", age: 60)
            let cookie = try await loginAsStudent("runner_detail_student", on: app)
            let response = try await detail("runner-private", cookie: cookie)
            #expect(response.status == .forbidden)
            #expect(!response.body.contains("private-host"))
        }
    }

    // MARK: - A pruned runner

    @Test func aPrunedRunnerIsRebuiltFromItsNewestSnapshot() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("runner_detail_admin", on: app)
            try await saveSnapshot(runnerID: "runner-pruned", hostname: "old-host", age: 3 * 3_600)
            try await saveSnapshot(runnerID: "runner-pruned", hostname: "new-host", age: 2 * 3_600)
            try await saveJob(runnerID: "runner-pruned", tag: "P1", status: "passed", cacheHit: nil)

            let response = try await detail("runner-pruned", cookie: cookie)

            #expect(response.status == .ok)
            #expect(response.body.contains("<span id=\"runner-hostname\">new-host</span>"))
            #expect(response.body.contains("<dt>Jobs processed</dt><dd>1</dd>"))
            // Two hours without a snapshot is offline, so the banner says so.
            #expect(response.body.contains("No heartbeat for "))
        }
    }

    // MARK: - Job rows and summary facts

    @Test func aTimedOutJobNamesTheLimitOfItsSetup() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("runner_detail_admin", on: app)
            try await saveSnapshot(runnerID: "runner-timeout", hostname: "t-host", age: 60)
            // The fixture manifest with another limit. The page reads only
            // `timeLimitSeconds`, so the grading mode does not matter here.
            let manifest = """
                {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],\
                "timeLimitSeconds":42,"makefile":null}
                """
            try await saveJob(
                runnerID: "runner-timeout", tag: "T1", status: "timeout", cacheHit: nil, manifest: manifest)

            let response = try await detail("runner-timeout", cookie: cookie)

            #expect(response.status == .ok)
            #expect(response.body.contains("hit the 42s limit"))
        }
    }

    @Test func aTimedOutJobWhoseManifestWillNotDecodeHasNoLimitNote() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("runner_detail_admin", on: app)
            try await saveSnapshot(runnerID: "runner-badmanifest", hostname: "b-host", age: 60)
            try await saveJob(
                runnerID: "runner-badmanifest", tag: "B1", status: "timeout", cacheHit: nil,
                manifest: "not json")

            let response = try await detail("runner-badmanifest", cookie: cookie)

            #expect(response.status == .ok)
            #expect(response.body.contains("Timed out"))
            #expect(!response.body.contains("hit the "))
        }
    }

    @Test func theCacheHitRateCountsOnlyJobsThatReportedOne() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("runner_detail_admin", on: app)
            try await saveSnapshot(runnerID: "runner-cache", hostname: "c-host", age: 60)
            try await saveJob(runnerID: "runner-cache", tag: "C1", status: "passed", cacheHit: true)
            try await saveJob(runnerID: "runner-cache", tag: "C2", status: "passed", cacheHit: true)
            try await saveJob(runnerID: "runner-cache", tag: "C3", status: "failed", cacheHit: false)
            try await saveJob(runnerID: "runner-cache", tag: "C4", status: "passed", cacheHit: nil)

            let response = try await detail("runner-cache", cookie: cookie)

            #expect(response.status == .ok)
            #expect(response.body.contains("<dt>Cache hit rate</dt><dd>67% (2/3)</dd>"))
        }
    }

    @Test func aRunnerWithNoCacheReportsShowsNoCacheHitRate() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("runner_detail_admin", on: app)
            try await saveSnapshot(runnerID: "runner-nocache", hostname: "n-host", age: 60)
            try await saveJob(runnerID: "runner-nocache", tag: "N1", status: "passed", cacheHit: nil)

            let response = try await detail("runner-nocache", cookie: cookie)

            #expect(response.status == .ok)
            #expect(!response.body.contains("Cache hit rate"))
        }
    }

    @Test func theCapabilityProfileBecomesTags() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("runner_detail_admin", on: app)
            try await saveSnapshot(runnerID: "runner-tags", hostname: "tag-host", age: 60)
            _ = try await app.runnerProfiles.registerOrUpdate(
                runnerID: "runner-tags", displayName: "tag-host",
                profile: RunnerCapabilityProfile(
                    platform: "linux",
                    architecture: "",
                    languageVersions: [LanguageVersion(language: "python", version: "3.12.1")],
                    capabilities: [RunnerCapability(name: "numpy")]
                ),
                seenAt: Date(), on: app.db)

            let response = try await detail("runner-tags", cookie: cookie)

            #expect(response.status == .ok)
            #expect(response.body.contains("<dt>Tags</dt>"))
            #expect(response.body.contains("<span class=\"chip\">linux</span>"))
            #expect(response.body.contains("<span class=\"chip\">python 3.12.1</span>"))
            #expect(response.body.contains("<span class=\"chip\">numpy</span>"))
            // An empty architecture is left out, not shown as an empty chip.
            #expect(!response.body.contains("<span class=\"chip\"></span>"))
        }
    }

    @Test func aRunnerWithNoProfileHasNoTags() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("runner_detail_admin", on: app)
            try await saveSnapshot(runnerID: "runner-untagged", hostname: "u-host", age: 60)

            let response = try await detail("runner-untagged", cookie: cookie)

            #expect(response.status == .ok)
            #expect(!response.body.contains("<dt>Tags</dt>"))
        }
    }
}
