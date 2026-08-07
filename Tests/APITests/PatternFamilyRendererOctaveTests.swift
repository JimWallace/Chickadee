// Tests/APITests/PatternFamilyRendererOctaveTests.swift
//
// Executes each rendered Octave pattern kind for real — against a CORRECT
// submission and a WRONG one, so both the pass and the failure path are seen.
// A parse-only check passes on code that cannot grade (the runbook's Lua
// lesson: a `#`-commented inputs file parsed fine by shebang accident), so
// every kind here runs under the actual `octave-cli` the worker spawns.
//
// Skipped silently when octave-cli is absent (a laptop without it is not a
// defect); `octaveIsPresentInCI` in OctaveNativeGradingTests is the
// did-not-skip proof that keeps this meaningful where it gates a merge.

import Core
import Foundation
import Testing

@testable import APIServer

/// Executes each rendered Octave kind for real. `run` writes the canonical
/// runtime, a stub submission and the generated script into a temp dir, runs
/// `octave-cli`, and returns the exit code (0 pass / 1 fail / 2 error).
@Suite(.serialized, .timeLimit(.minutes(3))) struct OctavePatternFamilyExecutionTests {

    static var hasOctave: Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["octave-cli", "--version"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// The canonical Octave runtime, read from the repo so the test exercises
    /// the same source the runner injects.
    static func canonicalRuntime() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // APITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        return try String(
            contentsOf: root.appendingPathComponent("Tools/runner-support/test_runtime.m"),
            encoding: .utf8)
    }

    static func run(
        script: GeneratedScript, submission: String, extraFiles: [String: String] = [:]
    ) throws -> Int32 {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ck-octfam-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try canonicalRuntime().write(
            to: dir.appendingPathComponent("test_runtime.m"), atomically: true, encoding: .utf8)
        try submission.write(
            to: dir.appendingPathComponent("solution.m"), atomically: true, encoding: .utf8)
        for (name, content) in extraFiles {
            try content.write(
                to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let scriptURL = dir.appendingPathComponent(script.filename)
        try script.source.write(to: scriptURL, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["octave-cli", scriptURL.path]
        proc.currentDirectoryURL = dir
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    private func single(
        kind: PatternKind, functionName: String, paramNames: [String],
        args: [JSONValue], expected: JSONValue, defaults: PatternDefaults = PatternDefaults()
    ) throws -> GeneratedScript {
        let fam = PatternFamily(
            id: "fam", name: "Fam", kind: kind, functionName: functionName,
            paramNames: paramNames, defaults: defaults,
            cases: [PatternCase(key: "01", label: "Case 1", args: args, expected: expected)])
        return try #require(renderPatternFamily(fam, language: .octave).first)
    }

    @Test func boundaryEqualityPassesAndFails() throws {
        guard Self.hasOctave else { return }
        let script = try single(
            kind: .boundaryEquality, functionName: "double_it", paramNames: ["x"],
            args: [.int(21)], expected: .int(42))
        #expect(
            try Self.run(
                script: script, submission: "function r = double_it(x)\n  r = x * 2;\nend\n") == 0)
        #expect(
            try Self.run(
                script: script, submission: "function r = double_it(x)\n  r = x + 2;\nend\n") == 1)
        // Missing function → errored (exit 2) via chickadee.require_fn.
        #expect(
            try Self.run(script: script, submission: "function r = other(x)\n  r = x;\nend\n") == 2)
    }

    /// The concatenation trap, executed: an expected value mixing a number and
    /// strings renders as a CELL — so a student who returns the cell passes and
    /// one who returns the silently-coerced char array fails, rather than the
    /// other way round.
    @Test func mixedExpectedValuesAreCellsNotCharCoercion() throws {
        guard Self.hasOctave else { return }
        let script = try single(
            kind: .boundaryEquality, functionName: "mixed", paramNames: ["x"],
            args: [.int(1)], expected: .array([.int(65), .string("bc")]))
        #expect(
            try Self.run(
                script: script, submission: "function r = mixed(x)\n  r = {65, \"bc\"};\nend\n") == 0)
        // `[65, "bc"]` in the student's own code IS "Abc" — and must fail.
        #expect(
            try Self.run(
                script: script, submission: "function r = mixed(x)\n  r = [65, \"bc\"];\nend\n") == 1)
    }

    /// An authored `null` is Octave's `NA`, and NA positions must survive:
    /// isequaln-based equality is what lets `[60, NA, 20]` match itself while
    /// plain isequal would fail it (NA is NaN-flavoured).
    @Test func nullArgsAndExpectationsBecomeNAs() throws {
        guard Self.hasOctave else { return }
        let script = try single(
            kind: .boundaryEquality, functionName: "stage_of", paramNames: ["e"],
            args: [.array([.double(60), .null, .double(20)])],
            expected: .array([.double(120), .null, .double(40)]))
        // Arithmetic propagates NA on its own, so the contract holds.
        #expect(
            try Self.run(
                script: script, submission: "function r = stage_of(e)\n  r = e * 2;\nend\n") == 0)
        // Dropping the NA (length 2, not 3) must fail rather than error.
        #expect(
            try Self.run(
                script: script,
                submission: "function r = stage_of(e)\n  r = e(!isnan(e)) * 2;\nend\n") == 1)
    }

    /// Row-vs-column must not fail a correct answer: the renderer emits rows,
    /// students' arithmetic freely produces columns, and `chickadee.equal`
    /// compares numeric values shape-blind (as R's recycling `==` does).
    @Test func aColumnResultMatchesARowExpectation() throws {
        guard Self.hasOctave else { return }
        let script = try single(
            kind: .boundaryEquality, functionName: "sorted_of", paramNames: ["x"],
            args: [.array([.int(3), .int(1), .int(2)])],
            expected: .array([.int(1), .int(2), .int(3)]))
        #expect(
            try Self.run(
                script: script,
                submission: "function r = sorted_of(x)\n  r = sort(x(:));\nend\n") == 0)
    }

    @Test func unorderedEqualityIgnoresOrderOnly() throws {
        guard Self.hasOctave else { return }
        let script = try single(
            kind: .unorderedEquality, functionName: "factors_of", paramNames: ["n"],
            args: [.int(6)], expected: .array([.int(1), .int(2), .int(3), .int(6)]))
        #expect(
            try Self.run(
                script: script,
                submission: "function r = factors_of(n)\n  r = [6, 3, 2, 1];\nend\n") == 0)
        #expect(
            try Self.run(
                script: script,
                submission: "function r = factors_of(n)\n  r = [6, 3, 2, 2];\nend\n") == 1)
    }

    @Test func approximateEqualityHonoursTolerance() throws {
        guard Self.hasOctave else { return }
        let script = try single(
            kind: .approximateEquality, functionName: "circle_area", paramNames: ["r"],
            args: [.int(2)], expected: .double(12.566),
            defaults: PatternDefaults(tolerance: 0.01))
        #expect(
            try Self.run(
                script: script,
                submission: "function a = circle_area(r)\n  a = pi * r * r;\nend\n") == 0)
        #expect(
            try Self.run(
                script: script,
                submission: "function a = circle_area(r)\n  a = 3 * r * r;\nend\n") == 1)
    }

    @Test func variableEqualityChecksAWorkspaceVariable() throws {
        guard Self.hasOctave else { return }
        let script = try single(
            kind: .variableEquality, functionName: "", paramNames: [],
            args: [.string("threshold")], expected: .int(42))
        #expect(try Self.run(script: script, submission: "threshold = 42;\n") == 0)
        #expect(try Self.run(script: script, submission: "threshold = 41;\n") == 1)
        #expect(try Self.run(script: script, submission: "other = 42;\n") == 1)
    }

    @Test func returnTypeCheckAcceptsCrossLanguageTypeNames() throws {
        guard Self.hasOctave else { return }
        // "str" is a Python spelling; the mapping accepts it so a converted
        // family keeps working.
        let script = try single(
            kind: .returnTypeCheck, functionName: "name_of", paramNames: ["x"],
            args: [.int(1)], expected: .string("str"))
        #expect(
            try Self.run(
                script: script,
                submission: "function r = name_of(x)\n  r = \"one\";\nend\n") == 0)
        #expect(
            try Self.run(script: script, submission: "function r = name_of(x)\n  r = 1;\nend\n")
                == 1)
    }

    @Test func exceptionExpectedRequiresTheError() throws {
        guard Self.hasOctave else { return }
        let script = try single(
            kind: .exceptionExpected, functionName: "must_throw", paramNames: ["x"],
            args: [.int(-1)], expected: .string("negative"))
        #expect(
            try Self.run(
                script: script,
                submission:
                    "function r = must_throw(x)\n  if x < 0\n    error(\"negative input\");\n  end\n  r = x;\nend\n"
            ) == 0)
        // Succeeding when an error was expected must fail.
        #expect(
            try Self.run(
                script: script, submission: "function r = must_throw(x)\n  r = x;\nend\n") == 1)
        // Raising the WRONG error must fail too.
        #expect(
            try Self.run(
                script: script,
                submission:
                    "function r = must_throw(x)\n  error(\"something else entirely\");\nend\n") == 1)
    }

    @Test func performanceThresholdFailsTheSlow() throws {
        guard Self.hasOctave else { return }
        let script = try single(
            kind: .performanceThreshold, functionName: "quick", paramNames: ["n"],
            args: [.int(1000)], expected: .int(2000))
        #expect(
            try Self.run(
                script: script, submission: "function r = quick(n)\n  r = sum(1:n);\nend\n") == 0)
        // ~2 CPU-bound seconds over a 2000 ms budget in interpreted Octave.
        #expect(
            try Self.run(
                script: script,
                submission: """
                    function r = quick(n)
                      r = 0;
                      t0 = time();
                      while (time() - t0) < 3
                        r = r + 1;
                      end
                    end
                    """) == 1)
    }

    @Test func stdoutEqualityCapturesPrintedOutput() throws {
        guard Self.hasOctave else { return }
        let script = try single(
            kind: .stdoutEquality, functionName: "greet", paramNames: ["name"],
            args: [.string("Ada")], expected: .string("Hello, Ada!"))
        #expect(
            try Self.run(
                script: script,
                submission: "function greet(name)\n  printf(\"Hello, %s!\\n\", name);\nend\n") == 0)
        // disp reaches the same stream evalc captures.
        #expect(
            try Self.run(
                script: script,
                submission: "function greet(name)\n  disp([\"Hello, \" name \"!\"]);\nend\n") == 0)
        #expect(
            try Self.run(
                script: script,
                submission: "function greet(name)\n  printf(\"Goodbye, %s!\\n\", name);\nend\n")
                == 1)
    }

    /// The existence guard the cases depend on: fail (exit 1), not error, so
    /// the runner's dependency gate skips the cases.
    @Test func existenceGuardFailsWhenTheFunctionIsMissing() throws {
        guard Self.hasOctave else { return }
        let fam = PatternFamily(
            id: "fam", name: "Fam", kind: .boundaryEquality, functionName: "double_it",
            paramNames: ["x"], defaults: PatternDefaults(),
            cases: [PatternCase(key: "01", label: "Case 1", args: [.int(1)], expected: .int(2))])
        let guardScript = try #require(existenceGuard(for: fam, language: .octave))
        #expect(
            try Self.run(
                script: guardScript,
                submission: "function r = double_it(x)\n  r = x * 2;\nend\n") == 0)
        #expect(
            try Self.run(script: guardScript, submission: "unrelated = 1;\n") == 1)
        #expect(
            try Self.run(script: guardScript, submission: "double_it = 42;\n") == 1)
    }

    /// A per-student expected value delivered through `_ck_inputs.m` — the
    /// whole `expectedVarRef` path executed, including the fail-closed message
    /// when the input is missing.
    @Test func perStudentExpectedValuesResolveFromTheInputsFile() throws {
        guard Self.hasOctave else { return }
        let fam = PatternFamily(
            id: "fam", name: "Fam", kind: .boundaryEquality, functionName: "double_it",
            paramNames: ["x"], defaults: PatternDefaults(),
            cases: [
                PatternCase(
                    key: "01", label: "Case 1", args: [.int(21)], expected: .int(0),
                    expectedVarRef: "expected_total")
            ])
        let script = try #require(
            renderPatternFamily(fam, perStudentNames: ["expected_total"], language: .octave).first)
        let inputs = AssignmentLanguage.octave.renderInputsFile([
            "expected_total": AssignmentLanguage.octave.literal(.int(42))
        ])
        #expect(
            try Self.run(
                script: script,
                submission: "function r = double_it(x)\n  r = x * 2;\nend\n",
                extraFiles: ["_ck_inputs.m": inputs]) == 0)
        // Without the inputs file the case must FAIL with the personalization
        // message, not silently compare against something else.
        #expect(
            try Self.run(
                script: script,
                submission: "function r = double_it(x)\n  r = x * 2;\nend\n") == 1)
    }
}
