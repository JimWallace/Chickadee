// Tests/APITests/AuditTockRegressionTests.swift
//
// Regression coverage for the v0.4.x "tock" audit fixes that previously had
// no test:
//   • Personalization M1 — the expression subprocess must not inherit (and
//     therefore must not leak) the server's environment secrets.
//   • Browser-runner H2 — a stored browser result must carry the
//     server-authoritative attempt number / first-pass flag, not the
//     browser's always-1 stamp.
//   • Personalization H3 — a pattern-family arg cell may reference an
//     assignment-scope global input via `$name` (the documented worked
//     example), which the validator previously rejected.
//
// The OAuth single-use/replay fixes (MCP H1) are already covered by
// MCPSecurityHardeningTests.authorizationCodeCannotBeReplayed,
// MCPOAuthFlowTests.consumedConsentTokenCannotBeReplayed, and
// .replayedRefreshTokenRevokesGrant — the atomic conditional UPDATE keeps
// those green.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct AuditTockRegressionTests {

    // MARK: - Personalization M1: no server-secret leakage

    @Test func evaluator_doesNotLeakServerEnvironmentSecrets() async throws {
        try await withAsyncEnvLock {
            setenv("CHICKADEE_AUDIT_FAKE_SECRET", "super-secret-value", 1)
            defer { unsetenv("CHICKADEE_AUDIT_FAKE_SECRET") }

            let result = try await PersonalizationEvaluator.evaluate(
                seedHex: "00ff",
                staticVariables: [],
                expressions: [
                    PersonalizationExpression(
                        name: "leaked",
                        expression:
                            "__import__('os').environ.get('CHICKADEE_AUDIT_FAKE_SECRET', 'LEAK_BLOCKED')"),
                    PersonalizationExpression(name: "shift", expression: "seed % 7"),
                ]
            )

            // The instructor expression cannot read the server's secret env var:
            // the subprocess gets an allowlisted env, not the inherited one.
            #expect(result["leaked"] == "'LEAK_BLOCKED'")
            #expect(result["leaked"]?.contains("super-secret-value") == false)
            // …and the interpreter still starts (PATH is allowlisted), so the
            // seed-derived expression still evaluates (0x00ff % 7 == 3).
            #expect(result["shift"] == "3")
        }
    }

    // MARK: - Browser-runner H2: server-authoritative attempt reconciliation

    @Test func reconcile_stampsServerAttemptAndRecomputesFirstPass() {
        let pass = TestOutcome(
            testName: "t1", testClass: nil, tier: .pub, status: .pass,
            shortResult: "ok", longResult: nil, points: 1, executionTimeMs: 1,
            memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: true)
        let fail = TestOutcome(
            testName: "t2", testClass: nil, tier: .pub, status: .fail,
            shortResult: "no", longResult: nil, points: 1, executionTimeMs: 1,
            memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: false)
        let browserCollection = TestOutcomeCollection(
            submissionID: "browser-local", testSetupID: "ts1", attemptNumber: 1,
            buildStatus: .passed, compilerOutput: nil, outcomes: [pass, fail],
            totalTests: 2, passCount: 1, failCount: 1, errorCount: 0, timeoutCount: 0,
            executionTimeMs: 5, runnerVersion: "browser/1.0", timestamp: Date())

        // A 3rd attempt: the server attempt number is stamped onto the
        // collection and every outcome, and a pass no longer counts as a
        // first-pass success.
        let r3 = BrowserResultRoutes.reconcileBrowserCollection(
            browserCollection, submissionID: "sub_abcd1234", attemptNumber: 3)
        #expect(r3.submissionID == "sub_abcd1234")
        #expect(r3.attemptNumber == 3)
        #expect(r3.outcomes.allSatisfy { $0.attemptNumber == 3 })
        #expect(r3.outcomes.first { $0.testName == "t1" }?.isFirstPassSuccess == false)

        // A 1st attempt: a pass IS a first-pass success; a fail is not.
        let r1 = BrowserResultRoutes.reconcileBrowserCollection(
            browserCollection, submissionID: "sub_x", attemptNumber: 1)
        #expect(r1.outcomes.first { $0.testName == "t1" }?.isFirstPassSuccess == true)
        #expect(r1.outcomes.first { $0.testName == "t2" }?.isFirstPassSuccess == false)
    }

    // MARK: - Personalization H3: pattern-family arg may reference a global input

    @Test func validator_acceptsGlobalVariableArgRef() throws {
        let family = PatternFamily(
            id: "greet", name: "Greeting", kind: .boundaryEquality,
            functionName: "greet", paramNames: ["name"],
            defaults: PatternDefaults(tier: .pub, points: 1, hint: nil),
            cases: [
                PatternCase(
                    key: "01", label: "uses global roster name",
                    args: [.string("placeholder")], expected: .string("hi"),
                    argVarRefs: ["roster_name"])
            ]
        )

        // Rejected when the referenced name isn't a known family/section/global
        // variable…
        #expect(throws: (any Error).self) {
            try validatePatternFamilies([family], testSuites: [])
        }
        // …accepted once it's declared as an assignment-scope global input
        // (matching what the renderer actually puts in scope).
        #expect(throws: Never.self) {
            try validatePatternFamilies(
                [family], testSuites: [], globalVariableNames: ["roster_name"])
        }
    }
}
