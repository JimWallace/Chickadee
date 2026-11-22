// Tests/APITests/Admin/ServerHealthAlertTests.swift
//
// The server health alerts, in three suites.
//
// `ServerHealthAlertTests` covers the pure deciders and the transition
// function.
//
// `ServerHealthAlertDatabaseRuleTests` covers the health rules that read the
// database, through `evaluateHealthRules`: the system-failure rate over the
// most recent grading jobs, the BrightSpace rule's list of failing
// assignments, and the database rule itself, which stops the evaluation of
// every rule that needs the database. These tests cover the queries and the
// counting in front of the deciders.
//
// `ServerHealthAlertMonitorTests` drives the monitor actor around the pure
// rules: which webhook URL wins, what a sweep records when a page is
// delivered or refused, the cooldown and the resolve message through a real
// sweep, the cap on the recent-firings buffer, and the boot stamp that the
// version-skew grace reads. No test there makes a network call: a refused
// page uses a webhook URL whose scheme `WebhookNotifier` rejects before it
// sends.

import Fluent
import FluentPostgresDriver
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct ServerHealthAlertTests {

    // MARK: - State machine transitions

    @Test func transitionEmitsOnFirstFire() {
        let now = Date()
        let evaluations: [HealthRule: RuleEvaluation] = [
            .runnerOffline: RuleEvaluation(isFiring: true, summary: "no runners", details: [:])
        ]
        let (newStates, transitions) = transitionAlerts(
            states: [:],
            evaluations: evaluations,
            cooldown: 1800,
            now: now
        )
        #expect(transitions.count == 1)
        #expect(transitions[0].rule == .runnerOffline)
        #expect(transitions[0].resolved == false)
        #expect(newStates[.runnerOffline]?.isFiring ?? false)
        #expect(newStates[.runnerOffline]?.lastFiredAt == now)
    }

    @Test func transitionDoesNotReFireWithinCooldown() {
        let firstFire = Date()
        let secondCheck = firstFire.addingTimeInterval(60)  // 1 min later
        let states: [HealthRule: AlertRuleState] = [
            .runnerOffline: AlertRuleState(isFiring: true, lastFiredAt: firstFire)
        ]
        let evaluations: [HealthRule: RuleEvaluation] = [
            .runnerOffline: RuleEvaluation(isFiring: true, summary: "still down", details: [:])
        ]
        let (newStates, transitions) = transitionAlerts(
            states: states,
            evaluations: evaluations,
            cooldown: 1800,
            now: secondCheck
        )
        #expect(transitions.isEmpty, "Should not re-fire within cooldown")
        #expect(newStates[.runnerOffline]?.lastFiredAt == firstFire)
    }

    @Test func transitionReFiresAfterCooldown() {
        let firstFire = Date()
        let afterCooldown = firstFire.addingTimeInterval(1900)  // > 30 min
        let states: [HealthRule: AlertRuleState] = [
            .runnerOffline: AlertRuleState(isFiring: true, lastFiredAt: firstFire)
        ]
        let evaluations: [HealthRule: RuleEvaluation] = [
            .runnerOffline: RuleEvaluation(isFiring: true, summary: "still down", details: [:])
        ]
        let (newStates, transitions) = transitionAlerts(
            states: states,
            evaluations: evaluations,
            cooldown: 1800,
            now: afterCooldown
        )
        #expect(transitions.count == 1, "Should re-fire after cooldown")
        #expect(transitions[0].resolved == false)
        #expect(newStates[.runnerOffline]?.lastFiredAt == afterCooldown)
    }

    @Test func transitionEmitsResolvedWhenRuleClears() {
        let firstFire = Date()
        let later = firstFire.addingTimeInterval(60)
        let states: [HealthRule: AlertRuleState] = [
            .runnerOffline: AlertRuleState(isFiring: true, lastFiredAt: firstFire)
        ]
        let evaluations: [HealthRule: RuleEvaluation] = [
            .runnerOffline: .ok
        ]
        let (newStates, transitions) = transitionAlerts(
            states: states,
            evaluations: evaluations,
            cooldown: 1800,
            now: later
        )
        #expect(transitions.count == 1)
        #expect(transitions[0].resolved)
        #expect(newStates[.runnerOffline]?.isFiring ?? true == false)
        // lastFiredAt is preserved so the next firing's cooldown is computed correctly.
        #expect(newStates[.runnerOffline]?.lastFiredAt == firstFire)
    }

    @Test func transitionFireResolveFireCycle() {
        var states: [HealthRule: AlertRuleState] = [:]
        let t0 = Date()

        // Fires at t0
        var (after, transitions) = transitionAlerts(
            states: states,
            evaluations: [.runnerOffline: RuleEvaluation(isFiring: true, summary: "down", details: [:])],
            cooldown: 1800,
            now: t0
        )
        #expect(transitions.count == 1)
        states = after

        // Resolves at t0+60
        (after, transitions) = transitionAlerts(
            states: states,
            evaluations: [.runnerOffline: .ok],
            cooldown: 1800,
            now: t0.addingTimeInterval(60)
        )
        #expect(transitions.count == 1)
        #expect(transitions[0].resolved)
        states = after

        // Fires again at t0+120 — well within cooldown of the FIRST fire,
        // but the rule transitioned ok→firing so it should emit anyway.
        (after, transitions) = transitionAlerts(
            states: states,
            evaluations: [.runnerOffline: RuleEvaluation(isFiring: true, summary: "down again", details: [:])],
            cooldown: 1800,
            now: t0.addingTimeInterval(120)
        )
        #expect(
            transitions.isEmpty, "After cooldown design: re-fire within cooldown is suppressed even after a resolve")
        // This documents the current behaviour: cooldown is global per-rule, not reset by resolution.
        // If we want resolution to reset cooldown, that's a follow-up.
    }

    @Test func transitionIndependentRulesDoNotInterfere() {
        let now = Date()
        let evaluations: [HealthRule: RuleEvaluation] = [
            .runnerOffline: RuleEvaluation(isFiring: true, summary: "a", details: [:]),
            .errorRateSpike: RuleEvaluation(isFiring: true, summary: "b", details: [:]),
            .queueBackedUp: .ok,
            .databaseUnreachable: .ok,
        ]
        let (_, transitions) = transitionAlerts(
            states: [:],
            evaluations: evaluations,
            cooldown: 1800,
            now: now
        )
        #expect(transitions.count == 2)
        let rules = Set(transitions.map(\.rule))
        #expect(rules == [.runnerOffline, .errorRateSpike])
    }

    // MARK: - Configuration

    @Test func configurationDefaults() {
        // No env vars touched — uses literal defaults from `default`.
        let config = ServerHealthAlertConfiguration.default
        #expect(config.enabled == false)
        #expect(config.queueDepthThreshold == 25)
        #expect(abs(config.errorRateThreshold - 0.30) < 0.001)
        #expect(config.cooldownSeconds == 1800)
        #expect(config.runnerOfflineSeconds == 300)
    }

    // MARK: - Runner offline rule

    private func presence(offline: Bool, known: Bool) -> RunnerPresenceState {
        RunnerPresenceState(recentWithinOffline: offline, anyKnownRunner: known)
    }

    @Test func runnerOffline_firesWhenJobsQueuedAndNoRecentRunner() {
        let evaluation = decideRunnerOffline(
            pending: PendingQueueState(pendingCount: 3, oldestPendingAge: 120),
            presence: presence(offline: false, known: true),
            offlineSeconds: 300
        )
        #expect(evaluation.isFiring)
        #expect(evaluation.details["pending_count"] == "3")
    }

    @Test func runnerOffline_okWhenRunnerRecent() {
        let evaluation = decideRunnerOffline(
            pending: PendingQueueState(pendingCount: 3, oldestPendingAge: 10),
            presence: presence(offline: true, known: true),
            offlineSeconds: 300
        )
        #expect(evaluation.isFiring == false)
    }

    @Test func runnerOffline_firesWithEmptyQueueWhenKnownRunnerGoesQuiet() {
        // Queue state is not a gate: a runner we've seen this session that has
        // gone quiet past the offline grace fires even with nothing pending.
        let evaluation = decideRunnerOffline(
            pending: .empty,
            presence: presence(offline: false, known: true),
            offlineSeconds: 300
        )
        #expect(evaluation.isFiring)
        #expect(evaluation.details["pending_count"] == "0")
        #expect(evaluation.details["runner_offline_threshold_seconds"] == "300")
    }

    @Test func runnerOffline_okWithEmptyQueueWhenRunnerStillChecksIn() {
        let evaluation = decideRunnerOffline(
            pending: .empty,
            presence: presence(offline: true, known: true),
            offlineSeconds: 300
        )
        #expect(evaluation.isFiring == false)
    }

    @Test func runnerOffline_okWhenNoRunnerEverConnected() {
        // A deployment with no runners (e.g. browser-graded only) must not page
        // forever just because the store is empty.
        let evaluation = decideRunnerOffline(
            pending: .empty,
            presence: presence(offline: false, known: false),
            offlineSeconds: 300
        )
        #expect(evaluation.isFiring == false)
    }

    @Test func runnerPresence_distinguishesRecentKnownAndForgotten() async {
        let store = WorkerActivityStore()
        let now = Date()
        // Runner last seen 12 minutes ago: past the 10-min grace, still remembered.
        await store.markActive(workerID: "r1", hostname: "h1", at: now.addingTimeInterval(-720))

        let quiet = await store.runnerPresence(graceSeconds: 600, rememberSeconds: 3600, now: now)
        #expect(quiet.anyRecent == false)
        #expect(quiet.anyKnown)

        // A check-in 30s ago counts as recent.
        await store.markActive(workerID: "r1", hostname: "h1", at: now.addingTimeInterval(-30))
        let recent = await store.runnerPresence(graceSeconds: 600, rememberSeconds: 3600, now: now)
        #expect(recent.anyRecent)
        #expect(recent.anyKnown)

        // Beyond the remember window the runner is forgotten entirely.
        let forgotten = await store.runnerPresence(
            graceSeconds: 600,
            rememberSeconds: 3600,
            now: now.addingTimeInterval(4000)
        )
        #expect(forgotten.anyRecent == false)
        #expect(forgotten.anyKnown == false)
    }

    // MARK: - decideRunnerVersionSkew

    @Test func runnerVersionSkew_firesWhenRunnerBehindAndPastGrace() {
        let evaluation = decideRunnerVersionSkew(
            serverVersion: "0.4.641",
            runnerVersions: ["0.4.641", "0.4.635"],
            serverUptimeSeconds: 1000,
            graceSeconds: 900
        )
        #expect(evaluation.isFiring)
        #expect(evaluation.details["behind_count"] == "1")
        #expect(evaluation.details["server_version"] == "0.4.641")
        #expect(evaluation.details["oldest_runner_version"] == "0.4.635")
        #expect(evaluation.details["behind_versions"] == "0.4.635")
    }

    @Test func runnerVersionSkew_okWhenAllRunnersCurrent() {
        let evaluation = decideRunnerVersionSkew(
            serverVersion: "0.4.641",
            runnerVersions: ["0.4.641", "0.4.641"],
            serverUptimeSeconds: 100_000,
            graceSeconds: 900
        )
        #expect(evaluation.isFiring == false)
    }

    @Test func runnerVersionSkew_okWithinDeployGrace() {
        // The crux: a runner is a release behind, but the server only just booted
        // (still inside its refresh window). This must NOT page — otherwise every
        // blue/green deploy fires while step 8 catches the runner up.
        let evaluation = decideRunnerVersionSkew(
            serverVersion: "0.4.641",
            runnerVersions: ["0.4.640"],
            serverUptimeSeconds: 120,
            graceSeconds: 900
        )
        #expect(evaluation.isFiring == false)
    }

    @Test func runnerVersionSkew_okWhenNoRunnersKnown() {
        // A runner-less (e.g. browser-graded only) deployment never pages.
        let evaluation = decideRunnerVersionSkew(
            serverVersion: "0.4.641",
            runnerVersions: [],
            serverUptimeSeconds: 100_000,
            graceSeconds: 900
        )
        #expect(evaluation.isFiring == false)
    }

    @Test func runnerVersionSkew_skipsUnparseableRunnerVersions() {
        // A mock / third-party runner reporting a non-semver version is not
        // "behind" — it just can't be compared, so it must never page.
        let evaluation = decideRunnerVersionSkew(
            serverVersion: "0.4.641",
            runnerVersions: ["runner/1.0", "dev"],
            serverUptimeSeconds: 100_000,
            graceSeconds: 900
        )
        #expect(evaluation.isFiring == false)
    }

    @Test func runnerVersionSkew_countsOnlyBehindRunnersWhenFleetMixed() {
        let evaluation = decideRunnerVersionSkew(
            serverVersion: "0.4.641",
            runnerVersions: ["0.4.641", "0.4.638", "0.4.639"],
            serverUptimeSeconds: 100_000,
            graceSeconds: 900
        )
        #expect(evaluation.isFiring)
        #expect(evaluation.details["behind_count"] == "2")
        #expect(evaluation.details["oldest_runner_version"] == "0.4.638")
        #expect(evaluation.details["behind_versions"] == "0.4.638,0.4.639")
    }

    @Test func runnerVersionSkew_okWhenRunnerAheadOfServer() {
        // A runner ahead of the server (e.g. briefly mid-rollback) is not the
        // "behind" case this rule targets, so it stays quiet.
        let evaluation = decideRunnerVersionSkew(
            serverVersion: "0.4.641",
            runnerVersions: ["0.5.0"],
            serverUptimeSeconds: 100_000,
            graceSeconds: 900
        )
        #expect(evaluation.isFiring == false)
    }

    @Test func knownRunnerVersions_returnsOnlyRecentNonEmptyVersions() async {
        let store = WorkerActivityStore()
        let now = Date()
        // Current runner, seen just now.
        await store.markActive(workerID: "r1", hostname: "h1", runnerVersion: "0.4.641", at: now)
        // Old runner, seen 2h ago — beyond the remember window, dropped.
        await store.markActive(
            workerID: "r2", hostname: "h2", runnerVersion: "0.4.635",
            at: now.addingTimeInterval(-7200))
        // A keep-alive-only touch that never carried a version — omitted.
        await store.markActive(workerID: "r3", hostname: "h3", at: now)

        let versions = await store.knownRunnerVersionsByID(rememberSeconds: 3600, now: now).map(\.version)
        #expect(versions == ["0.4.641"])
    }

    // MARK: - Rule helpers

    @Test func healthRuleSeverity() {
        #expect(HealthRule.databaseUnreachable.severity == "critical")
        #expect(HealthRule.runnerOffline.severity == "warning")
        // A runner left behind can lack a sandbox fix (#2274), which the #1210
        // gate does not cover, so it's warning, not info.
        #expect(HealthRule.runnerVersionSkew.severity == "warning")
        #expect(HealthRule.queueBackedUp.severity == "warning")
        #expect(HealthRule.errorRateSpike.severity == "warning")
        #expect(HealthRule.editorKernelUnrecoverable.severity == "warning")
    }

    @Test func healthRulePaging() {
        // The sweep pages every rule, so none may be advisory (`info`),
        // runner version skew included.
        for rule in HealthRule.allCases {
            #expect(["critical", "warning"].contains(rule.severity), "\(rule.rawValue) should page the operator")
        }
    }

    // MARK: - decideEditorKernelUnrecoverable

    @Test func editorKernelUnrecoverable_firesAtThreshold() {
        let evaluation = decideEditorKernelUnrecoverable(failedCount: 2, threshold: 2, windowMinutes: 60)
        #expect(evaluation.isFiring)
        #expect(evaluation.details["recover_failed_count"] == "2")
        #expect(evaluation.details["window_minutes"] == "60")
    }

    @Test func editorKernelUnrecoverable_okBelowThreshold() {
        let evaluation = decideEditorKernelUnrecoverable(failedCount: 1, threshold: 2, windowMinutes: 60)
        #expect(evaluation.isFiring == false)
    }

    @Test func editorKernelUnrecoverable_okWhenThresholdDisabled() {
        // A zero/negative threshold must never fire, even with failures present.
        let evaluation = decideEditorKernelUnrecoverable(failedCount: 99, threshold: 0, windowMinutes: 60)
        #expect(evaluation.isFiring == false)
    }

    // MARK: - decideBrightspaceSyncFailing

    @Test func brightspaceSyncFailing_firesAtThreshold() {
        let evaluation = decideBrightspaceSyncFailing(
            errorCount: 3, threshold: 3, windowMinutes: 60, lastDetail: "HTTP 503")
        #expect(evaluation.isFiring)
        #expect(evaluation.details["error_count"] == "3")
        #expect(evaluation.details["last_error"] == "HTTP 503")
        #expect(evaluation.summary.contains("503"))
    }

    @Test func brightspaceSyncFailing_okBelowThreshold() {
        let evaluation = decideBrightspaceSyncFailing(
            errorCount: 2, threshold: 3, windowMinutes: 60, lastDetail: nil)
        #expect(evaluation.isFiring == false)
    }

    @Test func brightspaceSyncFailing_okWhenThresholdDisabled() {
        let evaluation = decideBrightspaceSyncFailing(
            errorCount: 99, threshold: 0, windowMinutes: 60, lastDetail: nil)
        #expect(evaluation.isFiring == false)
    }

    // MARK: - JobFailureClassification

    @Test func jobFailureClassification_studentTestErrorIsNotSystemFailure() {
        // `inferredFinalStatus` rolls a single student-code exception up into a
        // job-level `error`.  That must NOT trip the error-rate alert.
        #expect(
            JobFailureClassification.isSystemFailure(
                finalStatus: JobFinalStatus.error.rawValue,
                testsErrored: 1,
                testsTimedOut: 0
            ) == false)
    }

    @Test func jobFailureClassification_studentTestTimeoutIsNotSystemFailure() {
        // Same for per-test timeouts: a student's slow loop is a student problem,
        // not a platform problem.
        #expect(
            JobFailureClassification.isSystemFailure(
                finalStatus: JobFinalStatus.timeout.rawValue,
                testsErrored: 0,
                testsTimedOut: 1
            ) == false)
    }

    @Test func jobFailureClassification_jobErrorWithNoPerTestErrorsIsSystemFailure() {
        // finalStatus=error but no test was recorded as errored → runner-level failure.
        #expect(
            JobFailureClassification.isSystemFailure(
                finalStatus: JobFinalStatus.error.rawValue,
                testsErrored: 0,
                testsTimedOut: 0
            ))
    }

    @Test func jobFailureClassification_jobTimeoutWithNoPerTestTimeoutsIsSystemFailure() {
        // finalStatus=timeout but no test was recorded as timed out → job-level timeout.
        #expect(
            JobFailureClassification.isSystemFailure(
                finalStatus: JobFinalStatus.timeout.rawValue,
                testsErrored: 0,
                testsTimedOut: 0
            ))
    }

    @Test func jobFailureClassification_passedOrFailedIsNeverSystemFailure() {
        #expect(
            JobFailureClassification.isSystemFailure(
                finalStatus: JobFinalStatus.passed.rawValue,
                testsErrored: 0,
                testsTimedOut: 0
            ) == false)
        #expect(
            JobFailureClassification.isSystemFailure(
                finalStatus: JobFinalStatus.failed.rawValue,
                testsErrored: 0,
                testsTimedOut: 0
            ) == false)
    }

    @Test func jobFailureClassification_nilFinalStatusIsNotSystemFailure() {
        // Defensive: a metric row mid-write with no finalStatus shouldn't count.
        #expect(
            JobFailureClassification.isSystemFailure(
                finalStatus: nil,
                testsErrored: nil,
                testsTimedOut: nil
            ) == false)
    }

    @Test func jobFailureClassification_nilCountsTreatedAsZero() {
        // Test counts can be null for older rows; treat as 0 so the row qualifies
        // as a system failure when finalStatus is error/timeout.
        #expect(
            JobFailureClassification.isSystemFailure(
                finalStatus: JobFinalStatus.error.rawValue,
                testsErrored: nil,
                testsTimedOut: nil
            ))
        #expect(
            JobFailureClassification.isSystemFailure(
                finalStatus: JobFinalStatus.timeout.rawValue,
                testsErrored: nil,
                testsTimedOut: nil
            ))
    }

    // MARK: - evaluateQueueBackedUp

    @Test func queueBackedUp_freshRetestBurstDoesNotFire() {
        // Instructor-triggered retest enqueues 250 submissions; oldest is 5s old.
        // Depth exceeds the 25 default but nothing is stuck, so the rule must stay quiet.
        let pending = PendingQueueState(pendingCount: 250, oldestPendingAge: 5)
        let evaluation = evaluateQueueBackedUp(
            pending: pending,
            depthThreshold: 25,
            oldestPendingSeconds: 600
        )
        #expect(evaluation.isFiring == false)
    }

    @Test func queueBackedUp_oneStuckSubmissionFiresEvenAtLowDepth() {
        // A single submission has been pending for 20 minutes — the queue is stuck
        // even though depth (1) is far below the threshold.
        let pending = PendingQueueState(pendingCount: 1, oldestPendingAge: 1200)
        let evaluation = evaluateQueueBackedUp(
            pending: pending,
            depthThreshold: 25,
            oldestPendingSeconds: 600
        )
        #expect(evaluation.isFiring)
        #expect(
            evaluation.summary.contains("oldest pending"),
            "summary should describe the age breach, got: \(evaluation.summary)")
        #expect(
            !evaluation.summary.contains("pending (>= "),
            "depth context should be omitted when depth is below threshold")
    }

    @Test func queueBackedUp_largeAndStuckMentionsBothInSummary() {
        // Large pile AND oldest item exceeds the age threshold — fire and include
        // the depth context for the on-call responder.
        let pending = PendingQueueState(pendingCount: 218, oldestPendingAge: 1500)
        let evaluation = evaluateQueueBackedUp(
            pending: pending,
            depthThreshold: 25,
            oldestPendingSeconds: 600
        )
        #expect(evaluation.isFiring)
        #expect(evaluation.summary.contains("oldest pending 1500s"))
        #expect(evaluation.summary.contains("218 pending (>= 25)"))
    }

    @Test func queueBackedUp_emptyQueueDoesNotFire() {
        let evaluation = evaluateQueueBackedUp(
            pending: .empty,
            depthThreshold: 25,
            oldestPendingSeconds: 600
        )
        #expect(!evaluation.isFiring)
    }
}

// MARK: - Rules that read the database

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

// MARK: - The monitor actor

@Suite(.timeLimit(.minutes(2))) struct ServerHealthAlertMonitorTests {

    /// A scheme that `WebhookNotifier` refuses before any request, so a
    /// delivery fails without the network.
    private let refusedWebhookURL = "ftp://alerts.invalid/hook"

    private func configuration(
        enabled: Bool = false,
        cooldownSeconds: TimeInterval = 1800,
        webhookURL: String? = nil
    ) -> ServerHealthAlertConfiguration {
        let base = ServerHealthAlertConfiguration.default
        return ServerHealthAlertConfiguration(
            enabled: enabled,
            checkIntervalSeconds: base.checkIntervalSeconds,
            cooldownSeconds: cooldownSeconds,
            runnerOfflineSeconds: base.runnerOfflineSeconds,
            runnerVersionSkewGraceSeconds: base.runnerVersionSkewGraceSeconds,
            queueDepthThreshold: base.queueDepthThreshold,
            oldestPendingSeconds: base.oldestPendingSeconds,
            errorRateThreshold: base.errorRateThreshold,
            errorRateWindowSize: base.errorRateWindowSize,
            errorRateMinimumSamples: base.errorRateMinimumSamples,
            editorUnrecoverableThreshold: base.editorUnrecoverableThreshold,
            editorUnrecoverableWindowMinutes: base.editorUnrecoverableWindowMinutes,
            brightspaceSyncFailureThreshold: base.brightspaceSyncFailureThreshold,
            brightspaceSyncFailureWindowMinutes: base.brightspaceSyncFailureWindowMinutes,
            outboundFailureThreshold: base.outboundFailureThreshold,
            outboundFailureWindowMinutes: base.outboundFailureWindowMinutes,
            webhookURLFromEnvironment: webhookURL
        )
    }

    /// A fresh path in the temporary directory, with nothing at it.
    private func webhookFilePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-alert-webhook-\(UUID().uuidString)").path
    }

    private func lowDisk(_ app: Application) {
        app.diskSpaceProbe = { _ in DiskSpace(freeBytes: 4 << 30, totalBytes: 93 << 30) }
    }

    private func healthyDisk(_ app: Application) {
        app.diskSpaceProbe = { _ in DiskSpace(freeBytes: 50 << 30, totalBytes: 100 << 30) }
    }

    private func diskRecords(_ monitor: ServerHealthAlertMonitor) async -> [AlertFiringRecord] {
        await monitor.recentFiringsSnapshot().filter { $0.rule == HealthRule.diskSpaceLow.rawValue }
    }

    // MARK: - Which webhook URL wins

    @Test func theFileOnDiskBeatsTheEnvironmentValue() async throws {
        let path = webhookFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let monitor = ServerHealthAlertMonitor(
            configuration: configuration(webhookURL: "https://env.example/hook"), webhookURLFilePath: path)

        #expect(await monitor.effectiveWebhookURL() == "https://env.example/hook")

        try "  https://disk.example/hook\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(await monitor.effectiveWebhookURL() == "https://disk.example/hook")
    }

    @Test func anAdminOverrideWinsAndIsSavedForTheNextProcess() async throws {
        let path = webhookFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "https://disk.example/hook".write(toFile: path, atomically: true, encoding: .utf8)
        let monitor = ServerHealthAlertMonitor(
            configuration: configuration(webhookURL: "https://env.example/hook"), webhookURLFilePath: path)

        await monitor.setWebhookURL("  https://admin.example/hook  ")
        #expect(await monitor.effectiveWebhookURL() == "https://admin.example/hook")

        // A restarted server has no override in memory; it reads the saved file.
        let restarted = ServerHealthAlertMonitor(
            configuration: configuration(webhookURL: "https://env.example/hook"), webhookURLFilePath: path)
        #expect(await restarted.effectiveWebhookURL() == "https://admin.example/hook")
    }

    @Test func clearingTheOverrideRemovesTheFileAndFallsBackToTheEnvironment() async {
        let path = webhookFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let monitor = ServerHealthAlertMonitor(
            configuration: configuration(webhookURL: "https://env.example/hook"), webhookURLFilePath: path)

        await monitor.setWebhookURL("https://admin.example/hook")
        #expect(FileManager.default.fileExists(atPath: path))

        await monitor.setWebhookURL("   ")
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(await monitor.effectiveWebhookURL() == "https://env.example/hook")
    }

    // MARK: - The test alert

    @Test func aRefusedTestAlertIsRecordedWithItsErrorAndRethrown() async throws {
        try await withTestApp { app in
            let path = webhookFilePath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let monitor = ServerHealthAlertMonitor(
                configuration: configuration(webhookURL: refusedWebhookURL), webhookURLFilePath: path)

            await #expect(throws: WebhookNotifierError.self) {
                try await monitor.dispatchTestAlert(application: app)
            }

            let records = await monitor.recentFiringsSnapshot()
            let record = try #require(records.first)
            #expect(records.count == 1)
            #expect(record.rule == HealthRule.runnerOffline.rawValue)
            #expect(record.paged)
            #expect(!record.delivered)
            #expect(record.deliveryError == "Invalid webhook URL: \(refusedWebhookURL)")
            #expect(record.summary.contains("Test alert"))
        }
    }

    @Test func theRecentFiringsBufferKeepsOnlyTheNewestFifty() async throws {
        try await withTestApp { app in
            let path = webhookFilePath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let monitor = ServerHealthAlertMonitor(configuration: configuration(), webhookURLFilePath: path)

            for _ in 0..<(ServerHealthAlertMonitor.recentFiringsCap + 3) {
                _ = try await monitor.dispatchTestAlert(application: app)
            }

            let records = await monitor.recentFiringsSnapshot()
            #expect(records.count == ServerHealthAlertMonitor.recentFiringsCap)
            let undelivered = records.count { !$0.delivered }
            #expect(undelivered == 0)
        }
    }

    // MARK: - A sweep

    @Test func aSweepRecordsAFiringRuleAndTheReasonItsPageFailed() async throws {
        try await withTestApp { app in
            lowDisk(app)
            let path = webhookFilePath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let monitor = ServerHealthAlertMonitor(
                configuration: configuration(webhookURL: refusedWebhookURL), webhookURLFilePath: path)

            await monitor.sweep(application: app)

            let records = await diskRecords(monitor)
            let record = try #require(records.first)
            #expect(records.count == 1)
            #expect(!record.resolved)
            #expect(record.paged)
            #expect(!record.delivered)
            #expect(record.deliveryError == "Invalid webhook URL: \(refusedWebhookURL)")
            let states = await monitor.currentRuleStates()
            #expect(states[.diskSpaceLow]?.isFiring == true)
        }
    }

    @Test func aSweepPagesOnceWithinTheCooldownAndSaysWhenTheRuleResolves() async throws {
        try await withTestApp { app in
            lowDisk(app)
            let path = webhookFilePath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let monitor = ServerHealthAlertMonitor(
                configuration: configuration(cooldownSeconds: 600), webhookURLFilePath: path)
            let start = Date()

            await monitor.sweep(application: app, now: start)
            await monitor.sweep(application: app, now: start.addingTimeInterval(60))
            var records = await diskRecords(monitor)
            #expect(records.count == 1, "a second sweep inside the cooldown does not page again")
            #expect(records.first?.delivered == true)
            #expect(records.first?.deliveryError == nil)

            healthyDisk(app)
            await monitor.sweep(application: app, now: start.addingTimeInterval(120))
            records = await diskRecords(monitor)
            let resolved = try #require(records.first)
            #expect(records.count == 2)
            #expect(resolved.resolved)
            #expect(resolved.summary == "RESOLVED: \(HealthRule.diskSpaceLow.humanReadable)")
            let states = await monitor.currentRuleStates()
            #expect(states[.diskSpaceLow]?.isFiring == false)
        }
    }

    // MARK: - Boot

    @Test func bootStampsTheStartTimeEvenWhenAlertsAreOff() async throws {
        try await withTestApp { app in
            app.serverHealthAlertConfiguration = configuration(enabled: false)
            let stale = Date(timeIntervalSince1970: 0)
            app.serverStartedAt = stale

            try await ServerHealthAlertLifecycleHandler().didBootAsync(app)

            #expect(app.serverStartedAt > stale.addingTimeInterval(86400))
            await ServerHealthAlertLifecycleHandler().shutdownAsync(app)
        }
    }
}
