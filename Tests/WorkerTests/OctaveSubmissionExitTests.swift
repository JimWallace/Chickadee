// Tests/WorkerTests/OctaveSubmissionExitTests.swift
//
// An Octave test's result is its exit status, and the submission runs inside
// the test's process. Before the guard, an exit() or quit() in the
// submission's own code ended the test with the submission's status, and
// status 0 read as a pass. `ck_load_student` now shadows both builtins with
// command-line functions that raise an error when the submission calls them;
// the runtime's verdicts and the test script itself keep the builtins
// (docs/grading-integrity.md, phase 2).

import ChickadeeTestSupport
import Core
import Foundation
import RunnerCore
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) struct OctaveSubmissionExitTests {

    static let harness = NativeGradingHarness(
        language: .octave, solutionFilename: "solution.m", timeLimitSeconds: 30)

    private func runOne(submission: String, test: String) async throws -> TestOutcome {
        let dir = try Self.harness.makeWorkspace(submission: submission, scripts: ["publictest_exit.m": test])
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcomes = await Self.harness.runSuites([NativeGradingHarness.item("publictest_exit.m")], in: dir)
        return try #require(outcomes.first)
    }

    private static let wrappedCall = """
        % Test: add
        chickadee = test_runtime();
        student = chickadee.load_student();
        add = chickadee.require_fn(student, "add");
        try
            result = add(2, 3);
        catch err
            chickadee.failed(err.message);
        end
        if isequal(result, 5)
            chickadee.passed();
        end
        chickadee.failed("wrong sum");
        """

    @Test(.requiresOctave, arguments: ["exit(0);", "exit;", "quit(0);", "quit;"])
    func anExitInsideACalledFunctionIsNotAPass(exitCall: String) async throws {
        let outcome = try await runOne(
            submission: "function r = add(a, b)\n    \(exitCall)\nend\n", test: Self.wrappedCall)
        #expect(outcome.status == .fail, "status \(outcome.status), short: \(outcome.shortResult)")
        #expect(outcome.shortResult.contains("the submission ended the test"))
    }

    @Test(.requiresOctave) func anUnwrappedCallThatExitsIsNotAPass() async throws {
        let outcome = try await runOne(
            submission: "function r = add(a, b)\n    exit(0);\nend\n",
            test: """
                chickadee = test_runtime();
                student = chickadee.load_student();
                add = chickadee.require_fn(student, "add");
                if isequal(add(2, 3), 5)
                    chickadee.passed();
                end
                chickadee.failed("wrong sum");
                """)
        #expect(outcome.status == .fail, "status \(outcome.status), short: \(outcome.shortResult)")
        #expect(outcome.longResult?.contains("the submission ended the test") == true)
    }

    // An anonymous function the submission defines is a submission call too.
    @Test(.requiresOctave) func anExitInsideAnAnonymousFunctionIsNotAPass() async throws {
        let outcome = try await runOne(
            submission: "add = @(a, b) exit(0);\n",
            test: """
                chickadee = test_runtime();
                student = chickadee.load_student();
                add = chickadee.require_fn(student, "add");
                add(2, 3);
                chickadee.failed("returned");
                """)
        #expect(outcome.status == .fail, "status \(outcome.status), short: \(outcome.shortResult)")
        #expect(outcome.longResult?.contains("the submission ended the test") == true)
    }

    // A wrong function above a top-level exit: before the guard the exit ended
    // the test at load with status 0, a pass; now the test grades the function.
    @Test(.requiresOctave) func anExitInTheTopLevelCodeDoesNotEndTheTest() async throws {
        let outcome = try await runOne(
            submission: "function r = add(a, b)\n    r = a - b;\nend\nexit(0);\n", test: Self.wrappedCall)
        #expect(outcome.status == .fail, "status \(outcome.status), short: \(outcome.shortResult)")
        #expect(outcome.shortResult.contains("wrong sum"))
    }

    @Test(.requiresOctave) func theRuntimeVerdictsAreUnchanged() async throws {
        let pass = try await runOne(
            submission: "function r = add(a, b)\n    r = a + b;\nend\n", test: Self.wrappedCall)
        #expect(pass.status == .pass, "status \(pass.status), short: \(pass.shortResult)")

        let fail = try await runOne(
            submission: "function r = add(a, b)\n    r = a - b;\nend\n", test: Self.wrappedCall)
        #expect(fail.status == .fail, "status \(fail.status), short: \(fail.shortResult)")
    }

    // A hand-written test that ends with its own exit, directly or through a
    // helper of its own, still reaches the builtin after loading a submission.
    @Test(.requiresOctave, arguments: ["exit(0);", "finish(0);"])
    func theTestScriptsOwnExitIsUnchanged(ending: String) async throws {
        let outcome = try await runOne(
            submission: "function r = add(a, b)\n    r = a + b;\nend\n",
            test: """
                1;
                function finish(code)
                    exit(code);
                end
                chickadee = test_runtime();
                student = chickadee.load_student();
                if isequal(add(2, 3), 5)
                    printf("{\\"shortResult\\": \\"sum is right\\"}\\n");
                    \(ending)
                end
                exit(1);
                """)
        #expect(outcome.status == .pass, "status \(outcome.status), short: \(outcome.shortResult)")
        #expect(outcome.shortResult == "sum is right")
    }
}
