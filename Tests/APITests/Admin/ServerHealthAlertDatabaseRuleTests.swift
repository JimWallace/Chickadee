// Tests/APITests/Admin/ServerHealthAlertDatabaseRuleTests.swift
//
// The health rules that read the database, through `evaluateHealthRules`:
// the system-failure rate over the most recent grading jobs, the BrightSpace
// rule's list of failing assignments, and the database rule itself, which
// stops the evaluation of every rule that needs the database. The pure
// deciders are covered in `ServerHealthAlertTests`; these tests cover the
// queries and the counting in front of them.

import Fluent
import FluentPostgresDriver
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) struct ServerHealthAlertDatabaseRuleTests {

    private func configuration(
        errorRateThreshold: Double = 0.5,
        errorRateWindowSize: Int = 10,
        errorRateMinimumSamples: Int = 4,
        brightspaceSyncFailureThreshold: Int = 3
    ) -> ServerHealthAlertConfiguration {
        let base = ServerHealthAlertConfiguration.default
        return ServerHealthAlertConfiguration(
            enabled: false,
            checkIntervalSeconds: base.checkIntervalSeconds,
            cooldownSeconds: base.cooldownSeconds,
            runnerOfflineSeconds: base.runnerOfflineSeconds,
            runnerVersionSkewGraceSeconds: base.runnerVersionSkewGraceSeconds,
            queueDepthThreshold: base.queueDepthThreshold,
            oldestPendingSeconds: base.oldestPendingSeconds,
            errorRateThreshold: errorRateThreshold,
            errorRateWindowSize: errorRateWindowSize,
            errorRateMinimumSamples: errorRateMinimumSamples,
            editorUnrecoverableThreshold: base.editorUnrecoverableThreshold,
            editorUnrecoverableWindowMinutes: base.editorUnrecoverableWindowMinutes,
            brightspaceSyncFailureThreshold: brightspaceSyncFailureThreshold,
            brightspaceSyncFailureWindowMinutes: base.brightspaceSyncFailureWindowMinutes,
            outboundFailureThreshold: base.outboundFailureThreshold,
            outboundFailureWindowMinutes: base.outboundFailureWindowMinutes,
            webhookURLFromEnvironment: nil
        )
    }

    /// A finished grading job. `testsErrored` and `testsTimedOut` say whether
    /// student code explains an `error` or `timeout` status.
    private struct Job {
        var status: JobFinalStatus
        var testsErrored = 0
        var testsTimedOut = 0
        var completedSecondsAgo: TimeInterval = 60
    }

    private func seedJobs(_ jobs: [Job], on app: Application, now: Date) async throws {
        let course = try await makeTestCourse(on: app, code: "ALERT101")
        let courseID = try course.requireID()
        try await makeTestSetup(on: app, id: "setup_alert", courseID: courseID)
        let student = try await makeTestStudent(on: app, username: "alert_student")
        let studentID = try student.requireID()
        for (index, job) in jobs.enumerated() {
            let submissionID = "sub_alert_\(index)"
            try await makeTestSubmission(on: app, id: submissionID, setupID: "setup_alert", userID: studentID)
            let metric = JobExecutionMetric(
                submissionID: submissionID,
                jobID: submissionID,
                testSetupID: "setup_alert",
                courseID: courseID,
                assignmentID: nil,
                userID: studentID,
                runnerID: "runner-alert",
                kind: APISubmission.Kind.student,
                attemptNumber: 1,
                enqueuedAt: nil
            )
            metric.completedAt = now.addingTimeInterval(-job.completedSecondsAgo)
            metric.finalStatus = job.status.rawValue
            metric.testsErrored = job.testsErrored
            metric.testsTimedOut = job.testsTimedOut
            try await metric.save(on: app.db)
        }
    }

    // MARK: - System-failure rate

    @Test func runnerFailuresAtTheThresholdFireAndStudentErrorsDoNotCount() async throws {
        try await withTestApp { app in
            let now = Date()
            try await seedJobs(
                [
                    Job(status: .error),
                    Job(status: .timeout),
                    Job(status: .error, testsErrored: 1),
                    Job(status: .passed),
                ], on: app, now: now)

            let results = await evaluateHealthRules(on: app, configuration: configuration(), now: now)

            let evaluation = try #require(results[.errorRateSpike])
            #expect(evaluation.isFiring)
            #expect(evaluation.summary.hasPrefix("2 of the last 4 grading jobs (50%) failed in the runner"))
            #expect(evaluation.details["system_failure_count"] == "2")
            #expect(evaluation.details["sample_size"] == "4")
            #expect(evaluation.details["system_failure_rate_percent"] == "50")
            #expect(evaluation.details["threshold_percent"] == "50")
        }
    }

    @Test func aRateBelowTheThresholdStaysQuiet() async throws {
        try await withTestApp { app in
            let now = Date()
            try await seedJobs(
                [
                    Job(status: .error),
                    Job(status: .timeout, testsTimedOut: 2),
                    Job(status: .failed),
                    Job(status: .passed),
                ], on: app, now: now)

            let results = await evaluateHealthRules(on: app, configuration: configuration(), now: now)

            #expect(results[.errorRateSpike]?.isFiring == false)
        }
    }

    @Test func onlyTheMostRecentJobsInTheWindowAreCounted() async throws {
        try await withTestApp { app in
            let now = Date()
            // Four recent passes fill the window of four. The three older runner
            // failures fall outside it; counted, they would be 3 of 7 (43%).
            try await seedJobs(
                [
                    Job(status: .passed, completedSecondsAgo: 60),
                    Job(status: .passed, completedSecondsAgo: 120),
                    Job(status: .passed, completedSecondsAgo: 180),
                    Job(status: .passed, completedSecondsAgo: 240),
                    Job(status: .error, completedSecondsAgo: 3600),
                    Job(status: .error, completedSecondsAgo: 3700),
                    Job(status: .timeout, completedSecondsAgo: 3800),
                ], on: app, now: now)

            let results = await evaluateHealthRules(
                on: app,
                configuration: configuration(errorRateThreshold: 0.25, errorRateWindowSize: 4),
                now: now)

            #expect(results[.errorRateSpike]?.isFiring == false)
        }
    }

    @Test func aJobOlderThanSevenDaysIsNotASample() async throws {
        try await withTestApp { app in
            let now = Date()
            // Three recent passes are one short of the four samples the rule
            // needs. The runner failure from eight days ago is past the
            // seven-day retention; counted, it would make 1 of 4 (25%).
            try await seedJobs(
                [
                    Job(status: .passed, completedSecondsAgo: 60),
                    Job(status: .passed, completedSecondsAgo: 120),
                    Job(status: .passed, completedSecondsAgo: 180),
                    Job(status: .error, completedSecondsAgo: 8 * 86400),
                ], on: app, now: now)

            let results = await evaluateHealthRules(
                on: app, configuration: configuration(errorRateThreshold: 0.25), now: now)

            #expect(results[.errorRateSpike]?.isFiring == false)
        }
    }

    // MARK: - BrightSpace sync

    @Test func theBrightSpaceAlertNamesEachFailingAssignmentOnceNewestFirst() async throws {
        try await withTestApp { app in
            let rows: [(title: String, status: APIBrightSpaceSyncLog.Status, detail: String)] = [
                ("Lab 1", .error, "HTTP 500 from D2L"),
                ("", .error, "HTTP 502 from D2L"),
                ("Lab 2", .error, "HTTP 503 from D2L"),
                ("Lab 3", .success, ""),
                ("Lab 1", .error, "HTTP 504 from D2L"),
            ]
            for row in rows {
                let log = APIBrightSpaceSyncLog(
                    courseID: nil, testSetupID: "setup_bs", assignmentTitle: row.title, userID: nil,
                    username: "student", orgUnitID: nil, gradeObjectID: nil, points: nil,
                    status: row.status, detail: row.detail)
                try await log.save(on: app.db)
                try await Task.sleep(for: .milliseconds(5))
            }

            let results = await evaluateHealthRules(on: app, configuration: configuration())

            let evaluation = try #require(results[.brightspaceSyncFailing])
            #expect(evaluation.isFiring)
            #expect(evaluation.details["error_count"] == "4")
            #expect(evaluation.details["assignments"] == "Lab 1, Lab 2")
            #expect(evaluation.details["last_error"] == "HTTP 504 from D2L")
            #expect(!evaluation.summary.contains("Lab 3"))
        }
    }

    // MARK: - Database unreachable

    /// A runner that went quiet ten minutes ago, past the 300-second offline
    /// threshold. The control and the database test below both seed it.
    private func seedQuietRunner(on app: Application, now: Date) async {
        await app.workerActivityStore.markActive(
            workerID: "runner-quiet", hostname: "runner-host", lastHeartbeatAt: now.addingTimeInterval(-600),
            at: now.addingTimeInterval(-600))
    }

    /// The control for the next test: with the database up, the quiet runner
    /// makes the runner-offline rule fire.
    @Test func theQuietRunnerFiresWhileTheDatabaseIsUp() async throws {
        try await withTestApp { app in
            let now = Date()
            await seedQuietRunner(on: app, now: now)

            let results = await evaluateHealthRules(on: app, configuration: configuration(), now: now)

            #expect(results[.databaseUnreachable]?.isFiring == false)
            #expect(results[.runnerOffline]?.isFiring == true)
        }
    }

    @Test func anUnreachableDatabaseFiresAndSkipsTheRulesThatNeedIt() async throws {
        let app = try await makeTestingApplication { app in
            // Port 1 on loopback refuses the connection at once.
            let unreachable = SQLPostgresConfiguration(
                hostname: "127.0.0.1", port: 1, username: "nobody", password: "none",
                database: "none", tls: .disable)
            app.databases.use(.postgres(configuration: unreachable), as: .psql)
            app.diskSpaceProbe = { _ in DiskSpace(freeBytes: 50 << 30, totalBytes: 100 << 30) }
        }
        try await withApp(app) { app in
            let now = Date()
            // The runner-offline rule fires on this runner (the control above),
            // but it is not evaluated while the database is down.
            await seedQuietRunner(on: app, now: now)

            let results = await evaluateHealthRules(on: app, configuration: configuration(), now: now)

            let database = try #require(results[.databaseUnreachable])
            #expect(database.isFiring)
            #expect(database.summary.hasPrefix("The server cannot reach its database"))
            #expect(database.details["error"]?.isEmpty == false)
            #expect(results[.runnerOffline]?.isFiring == false)
            #expect(results[.runnerOffline]?.summary == "ok")
        }
    }
}
