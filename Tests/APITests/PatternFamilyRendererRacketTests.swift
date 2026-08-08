// Tests/APITests/PatternFamilyRendererRacketTests.swift
//
// The Racket renderer's bytes, EXECUTED: every pattern kind rendered by the
// real renderer and run through a real `racket` against a correct and a wrong
// submission. This is the done test the runbook demands — a renderer whose
// output is only ever parsed can ship a comparison that answers backwards or
// an exit code that maps to the wrong status and stay green.
//
// It also pins the property the whole design rests on: the SAME rendered
// bytes grade a `#lang htdp/bsl` submission (CS 135/115) and a `#lang racket`
// one (CS 136+). Every kind below is exercised against both dialects.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(5))) struct RacketRendererExecutionTests {

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

    /// The did-not-skip proof for the APITests job. Without it, a CI image
    /// missing `racket` turns every test below into a silent pass — the exact
    /// shape that let R's suites skip everywhere for a whole release series.
    @Test func racketIsPresentInCI() {
        guard ProcessInfo.processInfo.environment["CI"] != nil else { return }
        #expect(
            Self.racketAvailable,
            "racket absent: every Racket renderer execution test skipped silently")
    }

    /// Runs a rendered test in a workspace holding the canonical runtime, the
    /// submission and the student hint. Returns (exitCode, stdout).
    static func execute(
        script: String, submission: String, inputs: String? = nil
    ) throws -> (code: Int32, stdout: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-rktrender-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let runtime = repoRoot.appendingPathComponent("Tools/runner-support/test_runtime.rkt")
        try FileManager.default.copyItem(
            at: runtime, to: dir.appendingPathComponent("test_runtime.rkt"))
        try submission.write(
            to: dir.appendingPathComponent("solution.rkt"), atomically: true, encoding: .utf8)
        try "solution.rkt".write(
            to: dir.appendingPathComponent(".chickadee_student_module"),
            atomically: true, encoding: .utf8)
        if let inputs {
            try inputs.write(
                to: dir.appendingPathComponent("_ck_inputs.rkt"), atomically: true, encoding: .utf8)
        }
        // Named `case.rkt`, not `test.rkt`: the runtime's submission scan
        // excludes anything matching "test" so it cannot grade a test file, and
        // a name that collides would make this harness measure the wrong thing.
        try script.write(
            to: dir.appendingPathComponent("case.rkt"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["racket", "case.rkt"]
        process.currentDirectoryURL = dir
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func family(
        _ kind: PatternKind, function: String = "f", expected: JSONValue,
        args: [JSONValue] = [.int(3)], paramNames: [String] = ["x"]
    ) -> PatternFamily {
        PatternFamily(
            id: "fam", name: "Family", kind: kind,
            functionName: function, paramNames: paramNames,
            defaults: PatternDefaults(tier: .pub, points: 1, hint: nil),
            cases: [PatternCase(key: "01", label: "case", args: args, expected: expected)])
    }

    static func render(_ family: PatternFamily, perStudent: Set<String> = []) -> String {
        renderRacketPatternCase(
            family: family, case: family.cases[0],
            sectionVariables: [], specHash: "h", perStudentNames: perStudent)
    }

    /// The same body in both dialects, so one rendered script can be run
    /// against each.
    static func bothDialects(_ body: String) -> [String] {
        ["#lang htdp/bsl\n\(body)\n", "#lang racket\n\(body)\n"]
    }

    // MARK: - The property the design rests on

    @Test func oneRenderedTestGradesBothDialects() throws {
        guard Self.racketAvailable else { return }
        let script = Self.render(Self.family(.boundaryEquality, expected: .int(9)))
        for submission in Self.bothDialects("(define (f x) (* x x))") {
            let result = try Self.execute(script: script, submission: submission)
            #expect(result.code == 0, "dialect failed: \(submission)\n\(result.stdout)")
        }
    }

    // MARK: - Per-kind, pass AND fail

    @Test func boundaryEqualityPassesAndFails() throws {
        guard Self.racketAvailable else { return }
        let script = Self.render(Self.family(.boundaryEquality, expected: .int(9)))
        for submission in Self.bothDialects("(define (f x) (* x x))") {
            #expect(try Self.execute(script: script, submission: submission).code == 0)
        }
        for submission in Self.bothDialects("(define (f x) (+ x x))") {
            let bad = try Self.execute(script: script, submission: submission)
            #expect(bad.code == 1)
            #expect(bad.stdout.contains("wrong value"))
        }
    }

    /// The exact-vs-inexact trap: BSL reads `18.5` as the exact rational 37/2,
    /// so `equal?` would answer #f against a rendered flonum and mark a correct
    /// student wrong. The runtime compares numbers with `=` for this reason.
    @Test func exactAndInexactNumbersCompareEqual() throws {
        guard Self.racketAvailable else { return }
        let script = Self.render(
            Self.family(.boundaryEquality, expected: .double(18.5), args: [.int(1)]))
        for submission in Self.bothDialects("(define (f x) 18.5)") {
            let result = try Self.execute(script: script, submission: submission)
            #expect(result.code == 0, "exactness mismatch marked a correct answer wrong")
        }
    }

    /// A list argument is what BSL's `quote` refusal would have broken — the
    /// runtime binds arguments into the namespace instead.
    @Test func listArgumentsSurviveTheBSLQuoteRestriction() throws {
        guard Self.racketAvailable else { return }
        let script = Self.render(
            Self.family(
                .boundaryEquality, function: "total", expected: .int(6),
                args: [.array([.int(1), .int(2), .int(3)])], paramNames: ["lst"]))
        let body = """
            (define (total lst)
              (cond [(empty? lst) 0] [else (+ (first lst) (total (rest lst)))]))
            """
        for submission in Self.bothDialects(body) {
            let result = try Self.execute(script: script, submission: submission)
            #expect(result.code == 0, "list argument did not reach the student: \(result.stdout)")
        }
    }

    @Test func unorderedEqualityIgnoresOrderOnly() throws {
        guard Self.racketAvailable else { return }
        let script = Self.render(
            Self.family(
                .unorderedEquality, expected: .array([.int(1), .int(2), .int(3)])))
        let reversed = try Self.execute(
            script: script, submission: "#lang racket\n(define (f x) (list 3 2 1))\n")
        #expect(reversed.code == 0, "\(reversed.stdout)")
        let wrong = try Self.execute(
            script: script, submission: "#lang racket\n(define (f x) (list 1 2 4))\n")
        #expect(wrong.code == 1)
    }

    @Test func approximateEqualityHonoursTolerance() throws {
        guard Self.racketAvailable else { return }
        let script = Self.render(Self.family(.approximateEquality, expected: .double(1.0)))
        let close = try Self.execute(
            script: script, submission: "#lang racket\n(define (f x) 1.0000001)\n")
        #expect(close.code == 0, "\(close.stdout)")
        let far = try Self.execute(
            script: script, submission: "#lang racket\n(define (f x) 1.5)\n")
        #expect(far.code == 1)
    }

    @Test func variableEqualityReadsAModuleLevelValue() throws {
        guard Self.racketAvailable else { return }
        let script = Self.render(
            Self.family(.variableEquality, function: "threshold", expected: .int(42), args: []))
        for submission in Self.bothDialects("(define threshold 42)") {
            let result = try Self.execute(script: script, submission: submission)
            #expect(result.code == 0, "\(result.stdout)")
        }
        let wrong = try Self.execute(
            script: script, submission: "#lang racket\n(define threshold 7)\n")
        #expect(wrong.code == 1)
    }

    @Test func returnTypeCheckNamesTheNeutralType() throws {
        guard Self.racketAvailable else { return }
        let script = Self.render(Self.family(.returnTypeCheck, expected: .string("str")))
        let good = try Self.execute(
            script: script, submission: "#lang racket\n(define (f x) \"hello\")\n")
        #expect(good.code == 0, "\(good.stdout)")
        let bad = try Self.execute(
            script: script, submission: "#lang racket\n(define (f x) 5)\n")
        #expect(bad.code == 1)
    }

    @Test func exceptionExpectedMatchesTheMessage() throws {
        guard Self.racketAvailable else { return }
        let script = Self.render(Self.family(.exceptionExpected, expected: .string("boom")))
        let raises = try Self.execute(
            script: script, submission: "#lang racket\n(define (f x) (error \"boom\"))\n")
        #expect(raises.code == 0, "\(raises.stdout)")
        let returns = try Self.execute(
            script: script, submission: "#lang racket\n(define (f x) 1)\n")
        #expect(returns.code == 1)
    }

    @Test func performanceThresholdBoundsRuntime() throws {
        guard Self.racketAvailable else { return }
        let script = Self.render(Self.family(.performanceThreshold, expected: .int(5000)))
        let fast = try Self.execute(
            script: script, submission: "#lang racket\n(define (f x) x)\n")
        #expect(fast.code == 0, "\(fast.stdout)")
    }

    @Test func stdoutEqualityComparesPrintedOutput() throws {
        guard Self.racketAvailable else { return }
        let script = Self.render(Self.family(.stdoutEquality, expected: .string("hi")))
        let good = try Self.execute(
            script: script, submission: "#lang racket\n(define (f x) (display \"hi\"))\n")
        #expect(good.code == 0, "\(good.stdout)")
        let bad = try Self.execute(
            script: script, submission: "#lang racket\n(define (f x) (display \"bye\"))\n")
        #expect(bad.code == 1)
    }

    // MARK: - Existence guard

    @Test func existenceGuardFailsRatherThanErrors() throws {
        guard Self.racketAvailable else { return }
        let script = renderRacketExistenceGuard(
            family: Self.family(.boundaryEquality, expected: .int(1)), specHash: "h")
        let present = try Self.execute(
            script: script, submission: "#lang racket\n(define (f x) x)\n")
        #expect(present.code == 0, "\(present.stdout)")
        let missing = try Self.execute(
            script: script, submission: "#lang racket\n(define (g x) x)\n")
        // Exit 1, never 2: the dependency gate keys on a failure, and an error
        // would leave the dependent cases running against a missing function.
        #expect(missing.code == 1)
    }

    /// A submission that does not compile is the STUDENT's finding, so it is a
    /// failure of the test rather than a runner error.
    @Test func aBrokenSubmissionFailsWithAReadableMessage() throws {
        guard Self.racketAvailable else { return }
        let script = Self.render(Self.family(.boundaryEquality, expected: .int(9)))
        let broken = try Self.execute(
            script: script, submission: "#lang racket\n(define (f x) (+ x\n")
        #expect(broken.code == 1)
        #expect(broken.stdout.contains("could not be loaded"))
    }
}
