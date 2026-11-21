// Tests/APITests/Admin/AdminRunnersRoutesTests.swift
//
// Admin runners tab: wait-time units, the runner detail stage timing, and the
// per-course and per-worker counts behind it.
//
// Split out of AdminRoutesTests.swift; the helpers these suites share are in
// AdminRouteFixtures.swift.

import Core
import Fluent
import Foundation
import NIOFoundationCompat
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AdminRunnersRoutesTests: AdminRouteFixtures {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-runners")
    }

    // MARK: - Runners tab

    @Test func adminRunnersUsesScaledAvgWaitUnits() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let course = try await makeCourse(code: "WAIT101", name: "Wait Course")
            let courseID = try course.requireID()
            let setup = try await makeSetup(id: "setup_wait_admin", courseID: courseID)
            let student = try await makeUser(username: "wait_student", role: "student")
            let studentID = try student.requireID()
            let submission = try await makeSubmission(
                id: "sub_wait_admin",
                setupID: try setup.requireID(),
                userID: studentID
            )
            submission.workerID = "runner-wait"
            try await submission.update(on: app.db)

            let metric = JobExecutionMetric(
                submissionID: try submission.requireID(),
                jobID: try submission.requireID(),
                testSetupID: try setup.requireID(),
                courseID: courseID,
                assignmentID: nil,
                userID: studentID,
                runnerID: "runner-wait",
                kind: APISubmission.Kind.student,
                attemptNumber: 1,
                enqueuedAt: Date().addingTimeInterval(-120)
            )
            metric.completedAt = Date().addingTimeInterval(-10)
            metric.queueWaitMs = 65_000
            metric.executionMs = 4_000
            metric.totalProcessingMs = 69_000
            metric.finalStatus = "passed"
            try await metric.save(on: app.db)

            await app.workerActivityStore.markActive(
                workerID: "runner-wait",
                hostname: "runner-host",
                runnerVersion: "runner/1.0",
                maxConcurrentJobs: 2,
                activeJobs: 0,
                lastHeartbeatAt: Date()
            )

            try await app.asyncTest(
                .GET, "/admin/runners",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let json = try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [[String: Any]]
                    let row = try #require(json?.first(where: { ($0["workerID"] as? String) == "runner-wait" }))
                    #expect(row["avgQueueWaitFormatted"] as? String == "1m 5s")
                })

        }
    }

    @Test func runnerDetailShowsStageTimingBreakdownWhenAvailable() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let course = try await makeCourse(code: "RUN101", name: "Runner Detail")
            let courseID = try course.requireID()
            let setup = try await makeSetup(id: "setup_runner_detail", courseID: courseID)
            let student = try await makeUser(username: "runner_detail_student", role: "student")
            let studentID = try student.requireID()
            let submission = try await makeSubmission(
                id: "sub_runner_detail",
                setupID: try setup.requireID(),
                userID: studentID
            )
            submission.workerID = "runner-detail"
            try await submission.update(on: app.db)

            let metric = JobExecutionMetric(
                submissionID: try submission.requireID(),
                jobID: try submission.requireID(),
                testSetupID: try setup.requireID(),
                courseID: courseID,
                assignmentID: nil,
                userID: studentID,
                runnerID: "runner-detail",
                kind: APISubmission.Kind.student,
                attemptNumber: 1,
                enqueuedAt: Date().addingTimeInterval(-30)
            )
            metric.completedAt = Date().addingTimeInterval(-5)
            metric.queueWaitMs = 1_000
            metric.executionMs = 4_000
            metric.totalProcessingMs = 8_000
            metric.testSetupAcquireMs = 200
            metric.submissionDownloadMs = 150
            metric.workdirSetupMs = 10
            metric.submissionDirSetupMs = 15
            metric.submissionUnpackMs = 20
            metric.starterCleanupMs = 5
            metric.submissionPrepareMs = 35
            metric.runtimeHelperSetupMs = 15
            metric.makeStepMs = 25
            metric.finalStatus = "passed"
            // 12 MiB workspace footprint — verifies the new Peak Disk column.
            metric.workdirPeakBytes = 12 * 1024 * 1024
            try await metric.save(on: app.db)

            let snapshot = RunnerSnapshot(
                runnerID: "runner-detail",
                recordedAt: Date().addingTimeInterval(-60),
                activeJobs: 1,
                maxJobs: 2,
                availableCapacity: 1,
                hostname: "runner-host",
                runnerVersion: "runner/1.1",
                lastPollAt: Date().addingTimeInterval(-15),
                lastHeartbeatAt: Date().addingTimeInterval(-10),
                serverAssignedJobCountSinceStart: 1
            )
            try await snapshot.save(on: app.db)

            await app.workerActivityStore.markActive(
                workerID: "runner-detail",
                hostname: "runner-host",
                runnerVersion: "runner/1.1",
                maxConcurrentJobs: 2,
                activeJobs: 0,
                lastHeartbeatAt: Date()
            )

            try await app.asyncTest(
                .GET, "/admin/runners/runner-detail",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    // The stage-timing facts are <dl> rows on the detail page's
                    // facts block, so the label is a <dt> rather than the
                    // "<strong>Label:</strong>" the titlebar column used.
                    #expect(body.contains("<dt>Avg cache acquire</dt>"))
                    #expect(body.contains("200ms"))
                    #expect(body.contains("<dt>Avg download</dt>"))
                    #expect(body.contains("150ms"))
                    #expect(body.contains("<dt>Avg prep</dt>"))
                    #expect(body.contains("100ms"))
                    #expect(body.contains("sortable-table"))
                    #expect(body.contains("Active Jobs"))
                    #expect(body.contains("1 / 2"))
                    #expect(body.contains("Utilization %"))
                    #expect(body.contains(">Max Jobs<") == false)
                    #expect(body.contains(">Available<") == false)
                    // Peak Disk column shows the formatted bytes; Setup/Other column
                    // was removed in favour of it.
                    #expect(body.contains("peak disk 12.0 MB"))
                    #expect(body.contains("12.0 MB"))
                    #expect(body.contains(">Setup/Other<") == false)
                })

        }
    }

    // Validates the DB-side GROUP BY in assignmentCountsByCourse (incl. UUID
    // decode).
    @Test func assignmentCountsByCourseGroupsPerCourse() async throws {
        try await withApp(app) { _ in
            let courseA = try await makeCourse(code: "GRPA", name: "Group A")
            let courseB = try await makeCourse(code: "GRPB", name: "Group B")
            let aID = try courseA.requireID()
            let bID = try courseB.requireID()
            // Three assignments in A, one in B (distinct setups per assignment).
            for index in 1...3 {
                let setup = try await makeSetup(id: "setup_grp_a\(index)", courseID: aID)
                _ = try await makeAssignment(
                    testSetupID: try setup.requireID(), courseID: aID, title: "A\(index)")
            }
            let setupB = try await makeSetup(id: "setup_grp_b1", courseID: bID)
            _ = try await makeAssignment(testSetupID: try setupB.requireID(), courseID: bID, title: "B1")

            let counts = try await assignmentCountsByCourse(on: app.db)
            #expect(counts[aID] == 3)
            #expect(counts[bID] == 1)
        }
    }

    // Validates the (worker_id, status) GROUP BY in makeWorkerRows: assigned
    // jobs counted separately from processed (complete + failed), per worker.
    @Test func adminRunnersCountsAssignedAndProcessedPerWorker() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let course = try await makeCourse(code: "WRK101", name: "Worker Course")
            let courseID = try course.requireID()
            let setup = try await makeSetup(id: "setup_wrk_counts", courseID: courseID)
            let setupID = try setup.requireID()
            let student = try await makeUser(username: "wrk_counts_student", role: "student")
            let studentID = try student.requireID()

            func makeWorkerSubmission(_ id: String, worker: String, status: String) async throws {
                let submission = try await makeTestSubmission(
                    on: app, id: id, setupID: setupID, userID: studentID, status: status)
                submission.workerID = worker
                try await submission.update(on: app.db)
            }
            // runner-A: 2 complete + 1 failed = 3 processed, plus 1 assigned.
            try await makeWorkerSubmission("sub_wc1", worker: "runner-A", status: "complete")
            try await makeWorkerSubmission("sub_wc2", worker: "runner-A", status: "complete")
            try await makeWorkerSubmission("sub_wc3", worker: "runner-A", status: "failed")
            try await makeWorkerSubmission("sub_wc4", worker: "runner-A", status: "assigned")
            // runner-B: 1 complete.
            try await makeWorkerSubmission("sub_wc5", worker: "runner-B", status: "complete")

            for worker in ["runner-A", "runner-B"] {
                await app.workerActivityStore.markActive(
                    workerID: worker,
                    hostname: "runner-host",
                    runnerVersion: "runner/1.0",
                    maxConcurrentJobs: 2,
                    activeJobs: 0,
                    lastHeartbeatAt: Date()
                )
            }

            try await app.asyncTest(
                .GET, "/admin/runners",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let json = try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [[String: Any]]
                    let rowA = try #require(json?.first(where: { ($0["workerID"] as? String) == "runner-A" }))
                    let rowB = try #require(json?.first(where: { ($0["workerID"] as? String) == "runner-B" }))
                    #expect(rowA["assignedJobs"] as? Int == 1)
                    #expect(rowA["jobsProcessed"] as? Int == 3)
                    #expect(rowB["assignedJobs"] as? Int == 0)
                    #expect(rowB["jobsProcessed"] as? Int == 1)
                })
        }
    }
}
