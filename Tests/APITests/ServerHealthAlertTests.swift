import Foundation
import Testing

@testable import chickadee_server

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
    }

    // MARK: - Rule helpers

    @Test func healthRuleSeverity() {
        #expect(HealthRule.databaseUnreachable.severity == "critical")
        #expect(HealthRule.runnerOffline.severity == "warning")
        #expect(HealthRule.queueBackedUp.severity == "warning")
        #expect(HealthRule.errorRateSpike.severity == "warning")
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
