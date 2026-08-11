// Tests/WorkerTests/LuaNativeGradingTests.swift
//
// Native-worker grading of Lua, run for real: a workspace assembled the way the
// runner assembles one, a generated-shaped `.lua` test, and the actual
// `UnsandboxedScriptRunner` spawning `env lua` through `executeSuites`.
//
// WHY THIS PATH SPECIFICALLY. Instructor validation is enqueued as a
// `kind == .validation` submission and graded by the NATIVE worker, even for a
// browser-graded assignment. That is what made the exit-127 defect worse than
// it looked: `.lua` classified to an `env lua` subprocess while the runner image
// installed only python3 and r-base, so a purely browser-graded Lua assignment
// could not be validated either — and the browser→worker failover was a dead
// end for the same reason. No unit test covered it, and the browser smoke could
// not, because it never leaves the browser.
//
// The assertions here are about the WHOLE chain: the interpreter is reachable,
// the injected runtime is requirable under the name generated scripts use, exit
// codes map to outcome statuses, and the JSON footer becomes the shortResult.
// Skipped silently when `lua` is absent, matching the conformance matrix.

import Foundation
import RunnerCore
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(3))) struct LuaNativeGradingTests {

    static var luaAvailable: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["lua", "-v"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The did-not-skip proof for the WorkerTests job (audit F2). Every test
    /// below guards `luaAvailable` and returns silently when Lua is absent —
    /// right on a laptop, a silent hole in CI. `lua5.4` shipped in #1282 without
    /// being added to the CI image, so this whole suite skipped while reporting
    /// green. Under `CI`, Lua MUST be present; this cannot be satisfied by
    /// skipping.
    @Test func luaIsPresentInCI() {
        guard ProcessInfo.processInfo.environment["CI"] != nil else { return }
        #expect(
            Self.luaAvailable,
            """
            lua5.4 is absent in the CI image, so every native Lua grading test skipped silently. \
            Add it to .github/docker/ci-image/Dockerfile and the WorkerTests apt fallback in \
            swift-tests.yml.
            """)
    }

    /// A grading workspace shaped like the one `RunnerDaemon` materializes:
    /// the injected runtime, the student's submission, and the hint file that
    /// tells `chickadee.student_file()` which upload to grade.
    static func makeWorkspace(
        submission: String,
        scripts: [String: String]
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-luanative-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // The SAME embedded source the worker injects, not a fixture copy — so
        // a runtime change that breaks native grading fails here.
        try testRuntimeSource(for: .lua).write(
            to: dir.appendingPathComponent("test_runtime.lua"), atomically: true, encoding: .utf8)
        try submission.write(
            to: dir.appendingPathComponent("solution.lua"), atomically: true, encoding: .utf8)
        try "solution.lua".write(
            to: dir.appendingPathComponent(".chickadee_student_module"),
            atomically: true, encoding: .utf8)
        for (name, source) in scripts {
            try source.write(
                to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    static func runSuites(_ items: [SuiteItem], in dir: URL) async -> [TestOutcome] {
        let executor = NativeScriptExecutor(
            runner: UnsandboxedScriptRunner(), workDir: dir, overrides: [:])
        return await executeSuites(
            items, timeLimitSeconds: 30, attemptNumber: 1, executor: executor)
    }

    static func item(_ script: String) -> SuiteItem {
        SuiteItem(script: script, tier: .pub, displayName: script, dependsOn: [], points: 1)
    }

    /// The regression test for the defect: a `.lua` test is dispatched to a real
    /// interpreter and comes back with a status, not a command-not-found error.
    @Test func aLuaTestIsGradedByTheNativeWorker() async throws {
        guard Self.luaAvailable else { return }

        let passing = """
            local chickadee = require("test_runtime")
            local student = chickadee.load_student()
            local target = chickadee.require_fn(student, "double")
            local ok, result = pcall(target, 21)
            if not ok or result ~= 42 then
                chickadee.failed("double(21) should be 42")
            end
            chickadee.passed("Returned " .. chickadee.format(result))
            """
        let dir = try Self.makeWorkspace(
            submission: "function double(x) return x * 2 end\n",
            scripts: ["publictest_double.lua": passing])
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcomes = await Self.runSuites([Self.item("publictest_double.lua")], in: dir)
        let outcome = try #require(outcomes.first)
        #expect(
            outcome.status == .pass,
            """
            Native Lua grading did not pass: \(outcome.status) — \(outcome.shortResult). \
            An `error` with a command-not-found message means `lua` is missing from the \
            environment, which is the exit-127 defect: instructor validation of a Lua \
            assignment cannot pass, browser-graded or not.
            """)
        #expect(outcome.shortResult.contains("Returned 42"))
    }

    /// Exit 1 is a fail and exit 2 is an error, through the real subprocess
    /// boundary rather than a stubbed runner — the mapping generated Lua relies
    /// on when it calls `chickadee.failed` / `chickadee.errored`.
    @Test func exitCodesMapToOutcomeStatuses() async throws {
        guard Self.luaAvailable else { return }

        let dir = try Self.makeWorkspace(
            submission: "function double(x) return x end\n",
            scripts: [
                "publictest_fails.lua": """
                local chickadee = require("test_runtime")
                chickadee.failed("wrong value")
                """,
                "publictest_errors.lua": """
                local chickadee = require("test_runtime")
                chickadee.errored("could not set up")
                """,
            ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcomes = await Self.runSuites(
            [Self.item("publictest_errors.lua"), Self.item("publictest_fails.lua")], in: dir)
        let byName = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.testName, $0) })

        let failed = try #require(byName.values.first { $0.shortResult.contains("wrong value") })
        #expect(failed.status == .fail)
        let errored = try #require(byName.values.first { $0.shortResult.contains("could not set up") })
        #expect(errored.status == .error)
    }

    /// A submission whose own top-level code raises still has its functions
    /// graded — `chickadee.load_student()` swallows the runtime error
    /// deliberately, matching test_runtime.R. Worth pinning natively because it
    /// is the difference between one failing test and a whole suite of errors.
    @Test func aSubmissionThatRaisesAtTopLevelStillExposesItsFunctions() async throws {
        guard Self.luaAvailable else { return }

        let script = """
            local chickadee = require("test_runtime")
            local student = chickadee.load_student()
            local target = chickadee.require_fn(student, "double")
            local ok, result = pcall(target, 4)
            if not ok or result ~= 8 then chickadee.failed("double(4) should be 8") end
            chickadee.passed("ok")
            """
        let dir = try Self.makeWorkspace(
            submission: """
                function double(x) return x * 2 end
                error("this line blows up after the function is defined")
                """,
            scripts: ["publictest_double.lua": script])
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcomes = await Self.runSuites([Self.item("publictest_double.lua")], in: dir)
        let outcome = try #require(outcomes.first)
        #expect(outcome.status == .pass, "got \(outcome.status): \(outcome.shortResult)")
    }

    /// The per-student inputs file, written and read on the native path. The
    /// browser smoke supplies one as a fixture, which proves the reader and says
    /// nothing about the worker.
    @Test func perStudentInputsAreReadableOnTheNativePath() async throws {
        guard Self.luaAvailable else { return }

        let script = """
            local chickadee = require("test_runtime")
            local values = chickadee.inputs()
            if values["threshold"] ~= 42 then
                chickadee.failed("threshold was " .. tostring(values["threshold"]))
            end
            if values["holes"] == nil or #values["holes"] ~= 3 then
                chickadee.failed("holes did not survive the null")
            end
            chickadee.passed("inputs delivered")
            """
        let dir = try Self.makeWorkspace(
            submission: "x = 1\n", scripts: ["publictest_inputs.lua": script])
        defer { try? FileManager.default.removeItem(at: dir) }

        // Exactly what AssignmentLanguage.lua.renderInputsFile produces, with a
        // null inside a table — the case that needs `chickadee.NULL` to resolve.
        try """
        -- Auto-generated per-student grading inputs (issue #461). Do not edit.
        return {
            ["holes"] = {60, chickadee.NULL, 20},
            ["threshold"] = 42
        }
        """.write(
            to: dir.appendingPathComponent("_ck_inputs.lua"), atomically: true, encoding: .utf8)

        let outcomes = await Self.runSuites([Self.item("publictest_inputs.lua")], in: dir)
        let outcome = try #require(outcomes.first)
        #expect(outcome.status == .pass, "got \(outcome.status): \(outcome.shortResult)")
    }
}
