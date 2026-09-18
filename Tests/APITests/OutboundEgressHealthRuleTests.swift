// Tests/APITests/OutboundEgressHealthRuleTests.swift
//
// The rule that would have caught the Sept 2026 outage.
//
// Container egress died when the host's Docker iptables chains were destroyed.
// Every outbound call failed for 38 hours while all seven existing health rules
// stayed green, because each measures the server's own internals and internals
// were genuinely fine. These tests pin the behaviour that distinguishes "we
// cannot reach anything" from the two conditions it must NOT be confused with:
// a far end having a bad day, and a deployment that simply makes no outbound
// calls at all.

import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) struct OutboundEgressHealthRuleTests {

    private struct TransportFailure: Error {}

    /// The shipped thresholds: 3 failures, 30-minute window.
    private let configuration = ServerHealthAlertConfiguration.default

    private var window: TimeInterval {
        TimeInterval(configuration.outboundFailureWindowMinutes * 60)
    }

    // MARK: - Store windowing

    @Test func theSnapshotCountsOnlyAttemptsInsideTheWindow() async {
        let store = OutboundReachabilityStore()
        let now = Date()

        await store.record(success: false, destination: .brightspace, at: now.addingTimeInterval(-3600))
        await store.record(success: false, destination: .brightspace, at: now.addingTimeInterval(-60))

        let snapshot = await store.snapshot(window: window, now: now)
        #expect(snapshot.failuresInWindow == 1)
        #expect(snapshot.successesInWindow == 0)
    }

    @Test func theSnapshotNamesEveryFailingDestinationOnce() async {
        let store = OutboundReachabilityStore()
        let now = Date()

        await store.record(success: false, destination: .identityProvider, at: now)
        await store.record(success: false, destination: .identityProvider, at: now)
        await store.record(success: false, destination: .brightspace, at: now)

        let snapshot = await store.snapshot(window: window, now: now)
        #expect(snapshot.destinationsFailing == ["BrightSpace", "identity provider"])
    }

    // MARK: - Reachability means reached, not happy

    @Test func aResponseCountsAsReachedAndOnlyATransportErrorDoesNot() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            // Stands in for a 503 from the far end: it returned, so the network
            // path works and this must not read as a severed egress.
            let status = try await app.recordingReachability(.identityProvider) { 503 }
            #expect(status == 503)

            do {
                _ = try await app.recordingReachability(.identityProvider) {
                    throw TransportFailure()
                }
                Issue.record("the transport error should have propagated")
            } catch is TransportFailure {
                // expected
            }

            let snapshot = await app.outboundReachability.snapshot(window: window)
            #expect(snapshot.successesInWindow == 1)
            #expect(snapshot.failuresInWindow == 1)
        }
    }

    // MARK: - The rule

    private func evaluate(
        recording attempts: [(success: Bool, ageSeconds: TimeInterval)],
        now: Date = Date()
    ) async throws -> RuleEvaluation {
        let app = try await makeTestApp()
        var evaluation = RuleEvaluation.ok
        try await withApp(app) { app in
            for attempt in attempts {
                await app.outboundReachability.record(
                    success: attempt.success,
                    destination: .identityProvider,
                    at: now.addingTimeInterval(-attempt.ageSeconds)
                )
            }
            evaluation = await evaluateOutboundEgressFailing(
                on: app,
                configuration: configuration,
                now: now
            )
        }
        return evaluation
    }

    @Test func itFiresWhenEveryRecentAttemptFailed() async throws {
        let evaluation = try await evaluate(
            recording: [(false, 60), (false, 120), (false, 180)]
        )
        #expect(evaluation.isFiring)
        #expect(evaluation.details["failuresInWindow"] == "3")
        #expect(evaluation.details["successesInWindow"] == "0")
    }

    @Test func itStaysGreenWhenSomethingSucceededInTheWindow() async throws {
        // A flaky IdP produces a mix. Only uniform failure means the path is gone,
        // and this is the clause that keeps the rule from paging on a bad
        // afternoon at the far end.
        let evaluation = try await evaluate(
            recording: [(false, 60), (false, 120), (false, 180), (true, 240)]
        )
        #expect(!evaluation.isFiring)
    }

    @Test func itStaysGreenBelowTheFailureThreshold() async throws {
        let evaluation = try await evaluate(recording: [(false, 60), (false, 120)])
        #expect(!evaluation.isFiring)
    }

    @Test func itStaysGreenWhenNothingWasAttempted() async throws {
        // A local-auth deployment with no BrightSpace records nothing. Silence is
        // not evidence of a fault.
        let evaluation = try await evaluate(recording: [])
        #expect(!evaluation.isFiring)
        #expect(evaluation.summary == "ok")
    }

    @Test func itStaysGreenWhenTheFailuresAreOlderThanTheWindow() async throws {
        let evaluation = try await evaluate(
            recording: [(false, 3600), (false, 3700), (false, 3800)]
        )
        #expect(!evaluation.isFiring)
    }

    // MARK: - Wiring

    @Test func theRuleIsEvaluatedAlongsideTheOthers() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let results = await evaluateHealthRules(on: app, configuration: configuration)
            #expect(results[.outboundEgressFailing] != nil)
        }
    }

    @Test func aFiringRulePagesTheOperator() {
        // It is an outage the running process hides, so it must not be advisory.
        #expect(HealthRule.outboundEgressFailing.severity == "critical")
        #expect(HealthRule.outboundEgressFailing.pagesOperator)
    }
}
