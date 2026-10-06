// Tests/WorkerTests/LuaSubmissionExitTests.swift
//
// A Lua test's result is its exit status, and the submission runs inside the
// test's process. Before the guard, an os.exit in the submission's own code
// ended the test with the submission's status, and status 0 read as a pass.
// `load_student` now gives the submission's environment its own `os` whose
// exit raises an error; the runtime's verdicts keep the real os.exit
// (docs/grading-integrity.md, phase 2).

import ChickadeeTestSupport
import Core
import Foundation
import RunnerCore
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) struct LuaSubmissionExitTests {

    static let harness = NativeGradingHarness(
        language: .lua, solutionFilename: "solution.lua", timeLimitSeconds: 30)

    private func runOne(submission: String, test: String) async throws -> TestOutcome {
        let dir = try Self.harness.makeWorkspace(submission: submission, scripts: ["publictest_exit.lua": test])
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcomes = await Self.harness.runSuites([NativeGradingHarness.item("publictest_exit.lua")], in: dir)
        return try #require(outcomes.first)
    }

    private static let wrappedCall = """
        -- Test: add
        local chickadee = require("test_runtime")
        local student = chickadee.load_student()
        local ok, result = pcall(student.add, 2, 3)
        if not ok then chickadee.failed(tostring(result)) end
        if result == 5 then chickadee.passed() end
        chickadee.failed("wrong sum")
        """

    @Test(.requiresLua, arguments: ["os.exit(0)", "os.exit(true)", "os.exit()"])
    func anExitInsideACalledFunctionIsNotAPass(exitCall: String) async throws {
        let outcome = try await runOne(
            submission: "function add(a, b) \(exitCall) end\n", test: Self.wrappedCall)
        #expect(outcome.status == .fail, "status \(outcome.status), short: \(outcome.shortResult)")
        #expect(outcome.shortResult.contains("the submission ended the test"))
    }

    // A wrong function after a top-level exit: before the guard the exit ended
    // the test at load with status 0, a pass; now the test grades the function.
    @Test(.requiresLua) func anExitInTheTopLevelCodeDoesNotEndTheTest() async throws {
        let outcome = try await runOne(
            submission: "function add(a, b) return a - b end\nos.exit(0)\n", test: Self.wrappedCall)
        #expect(outcome.status == .fail, "status \(outcome.status), short: \(outcome.shortResult)")
        #expect(outcome.shortResult.contains("wrong sum"))
    }

    @Test(.requiresLua) func theRestOfOsStillWorks() async throws {
        let outcome = try await runOne(
            submission: "function add(a, b) return a + b + (os.time() > 0 and 0 or 1) end\n",
            test: Self.wrappedCall)
        #expect(outcome.status == .pass, "status \(outcome.status), short: \(outcome.shortResult)")
    }

    @Test(.requiresLua) func theRuntimeVerdictsAreUnchanged() async throws {
        let pass = try await runOne(submission: "function add(a, b) return a + b end\n", test: Self.wrappedCall)
        #expect(pass.status == .pass, "status \(pass.status), short: \(pass.shortResult)")

        let fail = try await runOne(submission: "function add(a, b) return a - b end\n", test: Self.wrappedCall)
        #expect(fail.status == .fail, "status \(fail.status), short: \(fail.shortResult)")
    }
}
