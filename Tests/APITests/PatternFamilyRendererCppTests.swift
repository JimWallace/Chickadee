// Tests/APITests/PatternFamilyRendererCppTests.swift
//
// The C++ renderer's bytes, EXECUTED: every pattern kind rendered by the
// real renderer, run through /bin/sh → g++ → the binary against a correct
// and a wrong submission. This is the done test the runbook demands — a
// renderer whose output is only ever parsed can ship a wrapper that never
// compiles, a comparison that answers backwards, or an exit code that maps
// to the wrong status, and stay green.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(5))) struct CppRendererExecutionTests {

    static var gppAvailable: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["g++", "--version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The did-not-skip proof for the APITests job.
    @Test func gppIsPresentInCI() {
        guard ProcessInfo.processInfo.environment["CI"] != nil else { return }
        #expect(Self.gppAvailable, "g++ absent: every C++ renderer execution test skipped silently")
    }

    /// Runs a rendered wrapper in a workspace holding the canonical runtime,
    /// the submission, and the student hint. Returns (exitCode, stdout).
    static func execute(
        script: String, submission: String, inputs: String? = nil
    ) throws -> (code: Int32, stdout: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-cpprender-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let runtime = repoRoot.appendingPathComponent("Tools/runner-support/test_runtime.hpp")
        try FileManager.default.copyItem(
            at: runtime, to: dir.appendingPathComponent("test_runtime.hpp"))
        try submission.write(
            to: dir.appendingPathComponent("solution.cpp"), atomically: true, encoding: .utf8)
        try "solution.cpp".write(
            to: dir.appendingPathComponent(".chickadee_student_module"),
            atomically: true, encoding: .utf8)
        if let inputs {
            try inputs.write(
                to: dir.appendingPathComponent("_ck_inputs.hpp"), atomically: true, encoding: .utf8)
        }
        try script.write(
            to: dir.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["test.sh"]
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
        args: [JSONValue] = [.int(3)]
    ) -> PatternFamily {
        PatternFamily(
            id: "fam", name: "Family", kind: kind,
            functionName: function, paramNames: ["x"],
            defaults: PatternDefaults(tier: .pub, points: 1, hint: nil),
            cases: [PatternCase(key: "01", label: "case", args: args, expected: expected)])
    }

    static func render(_ family: PatternFamily, perStudent: Set<String> = []) -> String {
        renderCppPatternCase(
            family: family, case: family.cases[0],
            sectionVariables: [], specHash: "h", perStudentNames: perStudent)
    }

    // One test per kind, pass AND fail against real submissions.

    @Test func boundaryEqualityPassesAndFails() throws {
        guard Self.gppAvailable else { return }
        let script = Self.render(Self.family(.boundaryEquality, expected: .int(9)))
        let good = try Self.execute(
            script: script, submission: "int f(int x) { return x * x; }\n")
        #expect(good.code == 0, "\(good.stdout)")
        let bad = try Self.execute(
            script: script, submission: "int f(int x) { return x + x; }\n")
        #expect(bad.code == 1)
        #expect(bad.stdout.contains("wrong value"))
    }

    @Test func unorderedEqualityIgnoresOrderOnly() throws {
        guard Self.gppAvailable else { return }
        let script = Self.render(
            Self.family(
                .unorderedEquality, expected: .array([.int(1), .int(2), .int(3)])))
        let reversed = try Self.execute(
            script: script,
            submission: "#include <vector>\nstd::vector<int> f(int) { return {3, 2, 1}; }\n")
        #expect(reversed.code == 0, "\(reversed.stdout)")
        let short = try Self.execute(
            script: script,
            submission: "#include <vector>\nstd::vector<int> f(int) { return {1, 2}; }\n")
        #expect(short.code == 1)
    }

    @Test func approximateEqualityUsesTheTolerance() throws {
        guard Self.gppAvailable else { return }
        var family = Self.family(.approximateEquality, expected: .double(0.3))
        family = PatternFamily(
            id: family.id, name: family.name, kind: family.kind,
            functionName: family.functionName, paramNames: family.paramNames,
            defaults: PatternDefaults(tier: .pub, points: 1, hint: nil, tolerance: 1e-6),
            cases: family.cases)
        let script = Self.render(family)
        let close = try Self.execute(
            script: script, submission: "double f(int) { return 0.1 + 0.2; }\n")
        #expect(close.code == 0, "\(close.stdout)")
        let far = try Self.execute(
            script: script, submission: "double f(int) { return 0.31; }\n")
        #expect(far.code == 1)
    }

    @Test func variableEqualityReadsAGlobal() throws {
        guard Self.gppAvailable else { return }
        let script = Self.render(
            Self.family(.variableEquality, function: "threshold", expected: .int(7), args: []))
        let good = try Self.execute(script: script, submission: "int threshold = 7;\n")
        #expect(good.code == 0, "\(good.stdout)")
        let bad = try Self.execute(script: script, submission: "int threshold = 8;\n")
        #expect(bad.code == 1)
    }

    @Test func returnTypeCheckMatchesTheNeutralTypeNames() throws {
        guard Self.gppAvailable else { return }
        let script = Self.render(Self.family(.returnTypeCheck, expected: .string("str")))
        let good = try Self.execute(
            script: script,
            submission: "#include <string>\nstd::string f(int) { return \"x\"; }\n")
        #expect(good.code == 0, "\(good.stdout)")
        let bad = try Self.execute(script: script, submission: "int f(int) { return 1; }\n")
        #expect(bad.code == 1)
        #expect(bad.stdout.contains("wrong return type"))
    }

    @Test func exceptionExpectedMatchesTheSubstring() throws {
        guard Self.gppAvailable else { return }
        let script = Self.render(Self.family(.exceptionExpected, expected: .string("negative")))
        let throwing = try Self.execute(
            script: script,
            submission: """
                #include <stdexcept>
                int f(int) { throw std::invalid_argument("negative input"); }
                """)
        #expect(throwing.code == 0, "\(throwing.stdout)")
        let silent = try Self.execute(script: script, submission: "int f(int) { return 1; }\n")
        #expect(silent.code == 1)
        #expect(silent.stdout.contains("no error raised"))
    }

    @Test func performanceThresholdTimesTheCall() throws {
        guard Self.gppAvailable else { return }
        let script = Self.render(Self.family(.performanceThreshold, expected: .int(2000)))
        // A trivial function is far under a 2s budget.
        let fast = try Self.execute(script: script, submission: "int f(int x) { return x; }\n")
        #expect(fast.code == 0, "\(fast.stdout)")
        // The wrapper compiled -O2 — pinned by the script bytes.
        #expect(script.contains("-O2"))
    }

    @Test func stdoutEqualityCapturesPrintfAndCout() throws {
        guard Self.gppAvailable else { return }
        let script = Self.render(
            Self.family(.stdoutEquality, expected: .string("hello 3\nvia cout\n")))
        let good = try Self.execute(
            script: script,
            submission: """
                #include <cstdio>
                #include <iostream>
                int f(int x) {
                    std::printf("hello %d\\n", x);
                    std::cout << "via cout\\n";
                    return 0;
                }
                """)
        #expect(good.code == 0, "\(good.stdout)")
        let bad = try Self.execute(
            script: script,
            submission: "#include <cstdio>\nint f(int) { std::puts(\"nope\"); return 0; }\n")
        #expect(bad.code == 1)
        #expect(bad.stdout.contains("wrong output"))
    }

    /// A throwing submission on a guarded kind is a graded FAIL with the
    /// shared first line, never a crash.
    @Test func anUnexpectedThrowIsAGradedFailure() throws {
        guard Self.gppAvailable else { return }
        let script = Self.render(Self.family(.boundaryEquality, expected: .int(9)))
        let throwing = try Self.execute(
            script: script,
            submission: "#include <stdexcept>\nint f(int) { throw std::runtime_error(\"boom\"); }\n")
        #expect(throwing.code == 1)
        #expect(throwing.stdout.contains("unexpected exception"))
        #expect(throwing.stdout.contains("boom"))
    }

    /// Per-student values flow: argVarRefs and expectedVarRef resolve through
    /// _ck_inputs.hpp when their names are per-student.
    @Test func perStudentReferencesResolveThroughTheInputsHeader() throws {
        guard Self.gppAvailable else { return }
        let psCase = PatternCase(
            key: "01", label: "ps", args: [.int(0)], expected: .int(0),
            argVarRefs: ["threshold"], expectedVarRef: "want")
        let family = PatternFamily(
            id: "fam", name: "Family", kind: .boundaryEquality,
            functionName: "f", paramNames: ["x"],
            defaults: PatternDefaults(tier: .pub, points: 1, hint: nil),
            cases: [psCase])
        let script = renderCppPatternCase(
            family: family, case: psCase,
            sectionVariables: [], specHash: "h",
            perStudentNames: ["threshold", "want"])
        let language = AssignmentLanguage.cpp
        let inputs = language.renderInputsFile([
            "threshold": language.literal(.int(21)),
            "want": language.literal(.int(42)),
        ])
        let good = try Self.execute(
            script: script,
            submission: "int f(int x) { return x * 2; }\n",
            inputs: inputs)
        #expect(good.code == 0, "\(good.stdout)")
    }
}
