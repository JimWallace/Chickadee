// Tests/APITests/Grading/BrowserResultReconcileTests.swift
//
// A browser-graded result reaches the server stamped with the browser's own
// view of the attempt: attempt 1, and a first-pass flag computed from that.
// `BrowserResultRoutes.reconcileBrowserCollection` replaces both with the
// server's answer before the result is stored.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct BrowserResultReconcileTests {

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

        // A third attempt: the server attempt number is stamped onto the
        // collection and every outcome, and a pass no longer counts as a
        // first-pass success.
        let r3 = BrowserResultRoutes.reconcileBrowserCollection(
            browserCollection, submissionID: "sub_abcd1234", attemptNumber: 3)
        #expect(r3.submissionID == "sub_abcd1234")
        #expect(r3.attemptNumber == 3)
        #expect(r3.outcomes.allSatisfy { $0.attemptNumber == 3 })
        #expect(r3.outcomes.first { $0.testName == "t1" }?.isFirstPassSuccess == false)

        // A first attempt: a pass is a first-pass success, and a fail is not.
        let r1 = BrowserResultRoutes.reconcileBrowserCollection(
            browserCollection, submissionID: "sub_x", attemptNumber: 1)
        #expect(r1.outcomes.first { $0.testName == "t1" }?.isFirstPassSuccess == true)
        #expect(r1.outcomes.first { $0.testName == "t2" }?.isFirstPassSuccess == false)
    }
}
