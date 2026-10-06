// Tests/WorkerTests/RSubmissionExitTests.swift
//
// An R test's result is its exit status, and the submission runs inside the
// test's process. Before the guard, a quit() or q() in the submission's own
// code ended the test with the submission's status, and status 0 read as a
// pass. `chickadee_load_student` now shadows both names for code defined in
// the submission's environment, so such a call stops with an error; the
// runtime's own verdicts keep the real quit() (docs/grading-integrity.md,
// phase 2).

import ChickadeeTestSupport
import Core
import Foundation
import RunnerCore
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) struct RSubmissionExitTests {

    static let harness = NativeGradingHarness(
        language: .r, solutionFilename: "solution.R", timeLimitSeconds: 30)

    private func runOne(submission: String, test: String) async throws -> TestOutcome {
        let dir = try Self.harness.makeWorkspace(submission: submission, scripts: ["publictest_exit.R": test])
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcomes = await Self.harness.runSuites([NativeGradingHarness.item("publictest_exit.R")], in: dir)
        return try #require(outcomes.first)
    }

    private static let wrappedCall = """
        # Test: add
        source("test_runtime.R")
        student <- chickadee_load_student()
        add <- chickadee_require_fn(student, "add")
        result <- tryCatch(add(2, 3), error = function(e) failed(conditionMessage(e)))
        if (identical(result, 5)) passed()
        failed("wrong sum")
        """

    @Test(.requiresRscript, arguments: ["quit(status = 0)", "q(status = 0)", "quit(save = \"no\")"])
    func anExitInsideACalledFunctionIsNotAPass(exitCall: String) async throws {
        let outcome = try await runOne(
            submission: "add <- function(a, b) \(exitCall)\n", test: Self.wrappedCall)
        #expect(outcome.status == .fail, "status \(outcome.status), short: \(outcome.shortResult)")
        #expect(outcome.shortResult.contains("the submission ended the test"))
    }

    @Test(.requiresRscript) func anUnwrappedCallThatExitsIsNotAPass() async throws {
        let outcome = try await runOne(
            submission: "add <- function(a, b) quit(status = 0)\n",
            test: """
                source("test_runtime.R")
                student <- chickadee_load_student()
                if (identical(chickadee_require_fn(student, "add")(2, 3), 5)) passed()
                failed("wrong sum")
                """)
        #expect(outcome.status != .pass, "status \(outcome.status), short: \(outcome.shortResult)")
    }

    // A wrong function after a top-level quit: before the guard the quit ended
    // the test at load with status 0, a pass; now the test grades the function.
    @Test(.requiresRscript) func anExitInTheTopLevelCodeDoesNotEndTheTest() async throws {
        let outcome = try await runOne(
            submission: "quit(status = 0)\nadd <- function(a, b) a - b\n", test: Self.wrappedCall)
        #expect(outcome.status == .fail, "status \(outcome.status), short: \(outcome.shortResult)")
        #expect(outcome.shortResult.contains("wrong sum"))
    }

    @Test(.requiresRscript) func theRuntimeVerdictsAreUnchanged() async throws {
        let pass = try await runOne(submission: "add <- function(a, b) a + b\n", test: Self.wrappedCall)
        #expect(pass.status == .pass, "status \(pass.status), short: \(pass.shortResult)")

        let fail = try await runOne(submission: "add <- function(a, b) a - b\n", test: Self.wrappedCall)
        #expect(fail.status == .fail, "status \(fail.status), short: \(fail.shortResult)")
    }
}
