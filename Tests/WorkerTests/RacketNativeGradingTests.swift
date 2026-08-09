// Tests/WorkerTests/RacketNativeGradingTests.swift
//
// The end-to-end proof for Racket's dispatch fix (audit F1): a generated `.rkt`
// test reaches a real `racket` and comes back with a STATUS, rather than being
// handed to `/bin/sh` and dying on its own leading `;`.
//
// WHY IT MATTERS MORE HERE THAN FOR ITS PEERS. Racket is upload-only, so the
// native worker is not one of two grading paths — it is the only one. Every
// generated Racket test reported `error` before this, and the sibling suites for
// Lua, Octave and C++ all existed while this one did not: the audit's F5 is
// exactly the observation that the newest language had the least coverage.
//
// Modelled on `LuaNativeGradingTests`, deliberately — same workspace shape, same
// did-not-skip proof — so the four read as one family rather than four
// inventions.

import Core
import Foundation
import RunnerCore
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(3))) struct RacketNativeGradingTests {

    static var racketAvailable: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["racket", "--version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The did-not-skip proof. Every test below returns silently when Racket is
    /// absent — correct on a laptop, a silent hole in CI, and precisely how a
    /// language ships with a suite that never runs.
    @Test func racketIsPresentInCI() {
        guard ProcessInfo.processInfo.environment["CI"] != nil else { return }
        #expect(
            Self.racketAvailable,
            """
            racket is absent in the CI image, so every native Racket grading test skipped \
            silently. Add it to .github/docker/ci-image/Dockerfile and the WorkerTests apt \
            fallback in swift-tests.yml.
            """)
    }

    /// A workspace shaped like the one `RunnerDaemon` materializes: the injected
    /// runtime, the student's submission, and the hint naming it.
    static func makeWorkspace(submission: String, scripts: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-racketnative-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // The SAME embedded source the worker injects — reached through
        // `runtimeHelperFiles(for:)` rather than the constant, so this also
        // proves the helper a Racket workspace gets is the one the loop
        // installs. That indirection is the F2 fix; before it, this file was
        // never written at all.
        for (name, source) in runtimeHelperFiles(for: .racket) {
            try source.write(
                to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try submission.write(
            to: dir.appendingPathComponent("solution.rkt"), atomically: true, encoding: .utf8)
        try "solution.rkt".write(
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

    /// The regression test for F1. The script opens with `; Test: …` — the exact
    /// shape that defeated the shebang check and the Python content sniff and
    /// fell through to `/bin/sh`, where the leading `;` is a syntax error and
    /// the run exits 2.
    @Test func aRacketTestIsGradedByTheNativeWorker() async throws {
        guard Self.racketAvailable else { return }

        let dir = try Self.makeWorkspace(
            submission: """
                #lang racket/base
                (define (double x) (* 2 x))
                """,
            scripts: [
                "publictest_fam_01.rkt": """
                ; Test: double
                #lang racket/base
                (exit 0)
                """
            ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcomes = await Self.runSuites([Self.item("publictest_fam_01.rkt")], in: dir)
        let outcome = try #require(outcomes.first)
        #expect(
            outcome.status == .pass,
            """
            A generated .rkt was not graded by racket — status \(outcome.status), \
            stderr: \(outcome.longResult ?? "none"). An `error` here with a shell syntax \
            complaint means the script fell through to /bin/sh: the dispatch fix regressed.
            """)
    }

    /// The exit-code contract holds through the real interpreter, not just
    /// through the classifier.
    @Test func exitCodesMapToOutcomeStatuses() async throws {
        guard Self.racketAvailable else { return }

        let dir = try Self.makeWorkspace(
            submission: "#lang racket/base\n(define (f) 1)\n",
            scripts: [
                "publictest_pass.rkt": "; pass\n#lang racket/base\n(exit 0)",
                "publictest_fail.rkt": "; fail\n#lang racket/base\n(exit 1)",
                "publictest_error.rkt": "; error\n#lang racket/base\n(exit 2)",
            ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcomes = await Self.runSuites(
            [
                Self.item("publictest_pass.rkt"),
                Self.item("publictest_fail.rkt"),
                Self.item("publictest_error.rkt"),
            ], in: dir)
        let byName = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.testName, $0.status) })
        #expect(byName["publictest_pass.rkt"] == .pass)
        #expect(byName["publictest_fail.rkt"] == .fail)
        #expect(byName["publictest_error.rkt"] == .error)
    }

    /// The runtime the worker installs is loadable by a generated test.
    ///
    /// `(require "test_runtime.rkt")` is the first line of every generated
    /// Racket test, and before F2 the file was never written into the workspace
    /// — so this is the assertion that the helper actually lands and parses,
    /// rather than that a constant exists in the binary.
    @Test func theInstalledRuntimeIsRequirableByAGeneratedTest() async throws {
        guard Self.racketAvailable else { return }

        let dir = try Self.makeWorkspace(
            submission: "#lang racket/base\n(define (f) 1)\n",
            scripts: [
                "publictest_requires.rkt": """
                ; Test: the runtime loads
                #lang racket/base
                (require "test_runtime.rkt")
                (exit 0)
                """
            ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcomes = await Self.runSuites([Self.item("publictest_requires.rkt")], in: dir)
        let outcome = try #require(outcomes.first)
        #expect(
            outcome.status == .pass,
            """
            A generated test could not `require` test_runtime.rkt — status \(outcome.status), \
            stderr: \(outcome.longResult ?? "none"). Either the helper is not being installed \
            (F2) or the embedded copy no longer parses.
            """)
    }
}
