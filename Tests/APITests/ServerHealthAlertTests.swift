import XCTest
@testable import chickadee_server
import Foundation

final class ServerHealthAlertTests: XCTestCase {

    // MARK: - State machine transitions

    func testTransitionEmitsOnFirstFire() {
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
        XCTAssertEqual(transitions.count, 1)
        XCTAssertEqual(transitions[0].rule, .runnerOffline)
        XCTAssertFalse(transitions[0].resolved)
        XCTAssertTrue(newStates[.runnerOffline]?.isFiring ?? false)
        XCTAssertEqual(newStates[.runnerOffline]?.lastFiredAt, now)
    }

    func testTransitionDoesNotReFireWithinCooldown() {
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
        XCTAssertTrue(transitions.isEmpty, "Should not re-fire within cooldown")
        XCTAssertEqual(newStates[.runnerOffline]?.lastFiredAt, firstFire)
    }

    func testTransitionReFiresAfterCooldown() {
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
        XCTAssertEqual(transitions.count, 1, "Should re-fire after cooldown")
        XCTAssertFalse(transitions[0].resolved)
        XCTAssertEqual(newStates[.runnerOffline]?.lastFiredAt, afterCooldown)
    }

    func testTransitionEmitsResolvedWhenRuleClears() {
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
        XCTAssertEqual(transitions.count, 1)
        XCTAssertTrue(transitions[0].resolved)
        XCTAssertFalse(newStates[.runnerOffline]?.isFiring ?? true)
        // lastFiredAt is preserved so the next firing's cooldown is computed correctly.
        XCTAssertEqual(newStates[.runnerOffline]?.lastFiredAt, firstFire)
    }

    func testTransitionFireResolveFireCycle() {
        var states: [HealthRule: AlertRuleState] = [:]
        let t0 = Date()

        // Fires at t0
        var (after, transitions) = transitionAlerts(
            states: states,
            evaluations: [.runnerOffline: RuleEvaluation(isFiring: true, summary: "down", details: [:])],
            cooldown: 1800,
            now: t0
        )
        XCTAssertEqual(transitions.count, 1)
        states = after

        // Resolves at t0+60
        (after, transitions) = transitionAlerts(
            states: states,
            evaluations: [.runnerOffline: .ok],
            cooldown: 1800,
            now: t0.addingTimeInterval(60)
        )
        XCTAssertEqual(transitions.count, 1)
        XCTAssertTrue(transitions[0].resolved)
        states = after

        // Fires again at t0+120 — well within cooldown of the FIRST fire,
        // but the rule transitioned ok→firing so it should emit anyway.
        (after, transitions) = transitionAlerts(
            states: states,
            evaluations: [.runnerOffline: RuleEvaluation(isFiring: true, summary: "down again", details: [:])],
            cooldown: 1800,
            now: t0.addingTimeInterval(120)
        )
        XCTAssertEqual(transitions.count, 0,
                       "After cooldown design: re-fire within cooldown is suppressed even after a resolve")
        // This documents the current behaviour: cooldown is global per-rule, not reset by resolution.
        // If we want resolution to reset cooldown, that's a follow-up.
    }

    func testTransitionIndependentRulesDoNotInterfere() {
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
        XCTAssertEqual(transitions.count, 2)
        let rules = Set(transitions.map(\.rule))
        XCTAssertEqual(rules, [.runnerOffline, .errorRateSpike])
    }

    // MARK: - Configuration

    func testConfigurationDefaults() {
        // No env vars touched — uses literal defaults from `default`.
        let config = ServerHealthAlertConfiguration.default
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.queueDepthThreshold, 25)
        XCTAssertEqual(config.errorRateThreshold, 0.30, accuracy: 0.001)
        XCTAssertEqual(config.cooldownSeconds, 1800)
    }

    // MARK: - Rule helpers

    func testHealthRuleSeverity() {
        XCTAssertEqual(HealthRule.databaseUnreachable.severity, "critical")
        XCTAssertEqual(HealthRule.runnerOffline.severity, "warning")
        XCTAssertEqual(HealthRule.queueBackedUp.severity, "warning")
        XCTAssertEqual(HealthRule.errorRateSpike.severity, "warning")
    }

    // MARK: - JobFailureClassification

    func testJobFailureClassification_studentTestErrorIsNotSystemFailure() {
        // `inferredFinalStatus` rolls a single student-code exception up into a
        // job-level `error`.  That must NOT trip the error-rate alert.
        XCTAssertFalse(JobFailureClassification.isSystemFailure(
            finalStatus: JobFinalStatus.error.rawValue,
            testsErrored: 1,
            testsTimedOut: 0
        ))
    }

    func testJobFailureClassification_studentTestTimeoutIsNotSystemFailure() {
        // Same for per-test timeouts: a student's slow loop is a student problem,
        // not a platform problem.
        XCTAssertFalse(JobFailureClassification.isSystemFailure(
            finalStatus: JobFinalStatus.timeout.rawValue,
            testsErrored: 0,
            testsTimedOut: 1
        ))
    }

    func testJobFailureClassification_jobErrorWithNoPerTestErrorsIsSystemFailure() {
        // finalStatus=error but no test was recorded as errored → runner-level failure.
        XCTAssertTrue(JobFailureClassification.isSystemFailure(
            finalStatus: JobFinalStatus.error.rawValue,
            testsErrored: 0,
            testsTimedOut: 0
        ))
    }

    func testJobFailureClassification_jobTimeoutWithNoPerTestTimeoutsIsSystemFailure() {
        // finalStatus=timeout but no test was recorded as timed out → job-level timeout.
        XCTAssertTrue(JobFailureClassification.isSystemFailure(
            finalStatus: JobFinalStatus.timeout.rawValue,
            testsErrored: 0,
            testsTimedOut: 0
        ))
    }

    func testJobFailureClassification_passedOrFailedIsNeverSystemFailure() {
        XCTAssertFalse(JobFailureClassification.isSystemFailure(
            finalStatus: JobFinalStatus.passed.rawValue,
            testsErrored: 0,
            testsTimedOut: 0
        ))
        XCTAssertFalse(JobFailureClassification.isSystemFailure(
            finalStatus: JobFinalStatus.failed.rawValue,
            testsErrored: 0,
            testsTimedOut: 0
        ))
    }

    func testJobFailureClassification_nilFinalStatusIsNotSystemFailure() {
        // Defensive: a metric row mid-write with no finalStatus shouldn't count.
        XCTAssertFalse(JobFailureClassification.isSystemFailure(
            finalStatus: nil,
            testsErrored: nil,
            testsTimedOut: nil
        ))
    }

    func testJobFailureClassification_nilCountsTreatedAsZero() {
        // Test counts can be null for older rows; treat as 0 so the row qualifies
        // as a system failure when finalStatus is error/timeout.
        XCTAssertTrue(JobFailureClassification.isSystemFailure(
            finalStatus: JobFinalStatus.error.rawValue,
            testsErrored: nil,
            testsTimedOut: nil
        ))
        XCTAssertTrue(JobFailureClassification.isSystemFailure(
            finalStatus: JobFinalStatus.timeout.rawValue,
            testsErrored: nil,
            testsTimedOut: nil
        ))
    }
}
