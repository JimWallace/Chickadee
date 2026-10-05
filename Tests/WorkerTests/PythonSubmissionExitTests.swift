// Tests/WorkerTests/PythonSubmissionExitTests.swift
//
// A Python test's result is its exit status, and the submission runs inside
// the test's process. Before the bootstrap guard, a `SystemExit` raised in the
// submission's own code ended the test with the submission's status, and
// status 0 read as a pass whatever the test would have decided. The guard turns
// such an exit into an error; exits from the test itself and from the runtime's
// verdict functions are unchanged (docs/grading-integrity.md, phase 2).

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) struct PythonSubmissionExitTests {

    static let harness = NativeGradingHarness(
        language: .python, solutionFilename: "solution.py", timeLimitSeconds: 30)

    private func runOne(submission: String, test: String) async throws -> TestOutcome {
        let dir = try Self.harness.makeWorkspace(submission: submission, scripts: ["publictest_exit.py": test])
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcomes = await Self.harness.runSuites([NativeGradingHarness.item("publictest_exit.py")], in: dir)
        return try #require(outcomes.first)
    }

    @Test func anExitInsideACalledFunctionIsAnErrorNotAPass() async throws {
        let outcome = try await runOne(
            submission: "import sys\ndef add(a, b):\n    sys.exit(0)\n",
            test: """
                # Test: add
                if student_module.add(2, 3) == 5:
                    passed()
                failed("wrong sum")
                """)
        #expect(outcome.status == .error, "status \(outcome.status), short: \(outcome.shortResult)")
        #expect(outcome.shortResult.contains("the submission ended the test"))
    }

    @Test func anExitInTheNotebooksTopLevelCodeIsAnErrorNotAPass() async throws {
        let outcome = try await runOne(
            submission: "import sys\nvalue = 1\nif __name__ == \"__main__\":\n    sys.exit(0)\n",
            test: """
                # Test: value
                import test_runtime as _tr
                state = _tr.student_main_state()
                failed("the check did not decide")
                """)
        #expect(outcome.status == .error, "status \(outcome.status), short: \(outcome.shortResult)")
        #expect(outcome.shortResult.contains("the submission ended the test"))
    }

    @Test func theTestsOwnExitIsUnchanged() async throws {
        let outcome = try await runOne(
            submission: "def add(a, b):\n    return a + b\n",
            test: """
                import sys
                if student_module.add(2, 3) == 5:
                    sys.exit(0)
                sys.exit(1)
                """)
        #expect(outcome.status == .pass, "status \(outcome.status), short: \(outcome.shortResult)")
    }

    @Test func theRuntimeVerdictsAreUnchanged() async throws {
        let pass = try await runOne(
            submission: "def add(a, b):\n    return a + b\n",
            test: "# Test: add\nif student_module.add(2, 3) == 5:\n    passed()\nfailed(\"wrong sum\")\n")
        #expect(pass.status == .pass, "status \(pass.status), short: \(pass.shortResult)")

        let fail = try await runOne(
            submission: "def add(a, b):\n    return a - b\n",
            test: "# Test: add\nif student_module.add(2, 3) == 5:\n    passed()\nfailed(\"wrong sum\")\n")
        #expect(fail.status == .fail, "status \(fail.status), short: \(fail.shortResult)")
    }
}
