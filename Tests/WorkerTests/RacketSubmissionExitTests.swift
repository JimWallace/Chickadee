// Tests/WorkerTests/RacketSubmissionExitTests.swift
//
// A Racket test's result is its exit status, and the submission runs inside the
// test's process. Before the guard, an `(exit ...)` in the submission's own
// code ended the test with the submission's status, and status 0 read as a
// pass. Every entry into the submission now runs under an exit handler that
// raises an `exn:fail`; the runtime's verdicts keep the real handler
// (docs/grading-integrity.md, phase 2).

import ChickadeeTestSupport
import Core
import Foundation
import RunnerCore
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(3))) struct RacketSubmissionExitTests {

    static let harness = NativeGradingHarness(
        language: .racket, solutionFilename: "solution.rkt", timeLimitSeconds: 60)

    private func runOne(submission: String, test: String) async throws -> TestOutcome {
        let dir = try Self.harness.makeWorkspace(
            submission: submission, scripts: ["publictest_exit.rkt": test])
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcomes = await Self.harness.runSuites([NativeGradingHarness.item("publictest_exit.rkt")], in: dir)
        return try #require(outcomes.first)
    }

    private static let wrappedCall = """
        ; Test: add
        #lang racket/base
        (require "test_runtime.rkt")
        (define ns (chickadee-load-student))
        (define result
          (with-handlers ([exn:fail? (lambda (e) (chickadee-failed (exn-message e)))])
            (chickadee-call ns 'add (list 2 3))))
        (if (equal? result 5) (chickadee-passed) (chickadee-failed "wrong sum"))
        """

    @Test(.requiresRacket) func anExitInsideACalledFunctionIsNotAPass() async throws {
        let outcome = try await runOne(
            submission: "#lang racket/base\n(define (add a b) (exit 0))\n", test: Self.wrappedCall)
        #expect(outcome.status == .fail, "status \(outcome.status), short: \(outcome.shortResult)")
        #expect(outcome.shortResult.contains("the submission ended the test"))
    }

    @Test(.requiresRacket) func anExitInTheModuleBodyIsNotAPass() async throws {
        let outcome = try await runOne(
            submission: "#lang racket/base\n(define (add a b) (- a b))\n(exit 0)\n", test: Self.wrappedCall)
        #expect(outcome.status == .fail, "status \(outcome.status), short: \(outcome.shortResult)")
        #expect(outcome.shortResult.contains("the submission ended the test"))
    }

    @Test(.requiresRacket) func theRuntimeVerdictsAreUnchanged() async throws {
        let pass = try await runOne(
            submission: "#lang racket/base\n(define (add a b) (+ a b))\n", test: Self.wrappedCall)
        #expect(pass.status == .pass, "status \(pass.status), short: \(pass.shortResult)")

        let fail = try await runOne(
            submission: "#lang racket/base\n(define (add a b) (- a b))\n", test: Self.wrappedCall)
        #expect(fail.status == .fail, "status \(fail.status), short: \(fail.shortResult)")
    }
}
