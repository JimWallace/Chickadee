// Tests/APITests/PatternFamilyRendererJavaTests.swift
//
// The Java renderer's bytes, EXECUTED: every pattern kind rendered by the real
// renderer, run through /bin/sh → javac → java against a correct and a wrong
// submission. This is the done test the runbook demands — a renderer whose
// output is only ever parsed can ship a wrapper that never compiles, a
// comparison that answers backwards, or an exit code that maps to the wrong
// status, and stay green.
//
// Java adds one case the other languages have no equivalent of: a submission
// that calls `System.exit(0)`. Without the sentinel the wrapper checks for,
// that reads as a PASS — every case in the assignment, silently — so it is
// asserted here rather than trusted.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(5))) struct JavaRendererExecutionTests {

    static var javacAvailable: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["javac", "--version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The did-not-skip proof for the APITests job.
    @Test func javacIsPresentInCI() {
        guard ProcessInfo.processInfo.environment["CI"] != nil else { return }
        #expect(
            Self.javacAvailable,
            "javac absent: every Java renderer execution test skipped silently")
    }

    /// Runs a rendered wrapper in a workspace holding the canonical runtime and
    /// the submission. Returns exit code, stdout and stderr — they carry
    /// different halves of the contract: `ck.failed` writes its JSON to stdout,
    /// `ck.errored` writes to stderr, which is what becomes `longResult`.
    ///
    /// The submission is named `Solution.java` because Java requires a public
    /// class to live in a file of its own name, and the families below target
    /// `Solution.f`. Nothing writes `.chickadee_student_module`: unlike C++, the
    /// wrapper never locates the submission — javac resolves `Solution` from the
    /// sourcepath on demand.
    static func execute(
        script: String, submission: String, inputs: String? = nil
    ) throws -> (code: Int32, stdout: String, stderr: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-javarender-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let runtime = repoRoot.appendingPathComponent("Tools/runner-support/test_runtime.java")
        try FileManager.default.copyItem(
            at: runtime, to: dir.appendingPathComponent("test_runtime.java"))
        try submission.write(
            to: dir.appendingPathComponent("Solution.java"), atomically: true, encoding: .utf8)
        if let inputs {
            try inputs.write(
                to: dir.appendingPathComponent("_ck_inputs.java"), atomically: true, encoding: .utf8)
        }
        try script.write(
            to: dir.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["test.sh"]
        process.currentDirectoryURL = dir
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: data, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }

    static func family(
        _ kind: PatternKind, function: String = "Solution.f", expected: JSONValue,
        args: [JSONValue] = [.int(3)], reference: String? = nil
    ) -> PatternFamily {
        PatternFamily(
            id: "fam", name: "Family", kind: kind,
            functionName: function, paramNames: ["x"],
            defaults: PatternDefaults(tier: .pub, points: 1, hint: nil),
            cases: [PatternCase(key: "01", label: "case", args: args, expected: expected)],
            referenceImplementation: reference)
    }

    static func render(_ family: PatternFamily, perStudent: Set<String> = []) -> String {
        renderJavaPatternCase(
            family: family, case: family.cases[0],
            sectionVariables: [], specHash: "h", perStudentNames: perStudent)
    }

    /// Wraps a method body in the public class the families target.
    static func solution(_ members: String) -> String {
        "public class Solution {\n\(members)\n}\n"
    }

    // MARK: - boundaryEquality

    @Test func boundaryEqualityPassesAndFails() throws {
        guard Self.javacAvailable else { return }
        let script = Self.render(Self.family(.boundaryEquality, expected: .int(6)))

        let good = try Self.execute(
            script: script, submission: Self.solution("static int f(int x) { return x * 2; }"))
        #expect(good.code == 0, "correct submission did not pass: \(good.stdout) \(good.stderr)")
        #expect(good.stdout.contains("Returned 6"))
        #expect(!good.stdout.contains("CK_SENTINEL"), "the sentinel leaked into the result line")

        let bad = try Self.execute(
            script: script, submission: Self.solution("static int f(int x) { return 99; }"))
        #expect(bad.code == 1, "wrong submission did not fail: \(bad.stdout) \(bad.stderr)")
        #expect(bad.stdout.contains("wrong value"))
        #expect(bad.stdout.contains("expected"), "the failure did not name the expected value")
    }

    /// THE CROSS-TYPE CASE, and the reason `ck.equal` is not `Object.equals`.
    /// An authored `6` is an `Integer`; a student returning `long` boxes to
    /// `Long`, and `Integer.valueOf(6).equals(Long.valueOf(6L))` is FALSE. A
    /// runtime that trusted `equals` would mark this correct submission wrong.
    @Test func aWiderReturnTypeStillMatchesAnAuthoredInteger() throws {
        guard Self.javacAvailable else { return }
        let script = Self.render(Self.family(.boundaryEquality, expected: .int(6)))
        let result = try Self.execute(
            script: script, submission: Self.solution("static long f(int x) { return x * 2L; }"))
        #expect(
            result.code == 0,
            """
            a student returning `long` was marked wrong against an authored int. \
            ck.equal must compare numbers numerically: \(result.stdout) \(result.stderr)
            """)
    }

    // MARK: - The System.exit hazard

    /// Java's per-language quirk, and the one that would be silent. A student
    /// calling `System.exit(0)` in their own code exits the JVM with status 0;
    /// without the sentinel the wrapper checks for, the case — and every case in
    /// the assignment — reads as a PASS.
    @Test func aSubmissionCallingSystemExitIsAnErrorNotAPass() throws {
        guard Self.javacAvailable else { return }
        let script = Self.render(Self.family(.boundaryEquality, expected: .int(6)))
        let result = try Self.execute(
            script: script,
            submission: Self.solution("static int f(int x) { System.exit(0); return 0; }"))
        #expect(
            result.code == 2,
            """
            a submission calling System.exit(0) produced exit \(result.code), not 2. \
            If this is 0, every test in every Java assignment reads as a pass.
            """)
        #expect(result.stderr.contains("System.exit"), "the error did not explain what happened")
    }

    // MARK: - A submission that does not compile

    @Test func aNonCompilingSubmissionIsAnError() throws {
        guard Self.javacAvailable else { return }
        let script = Self.render(Self.family(.boundaryEquality, expected: .int(6)))
        let result = try Self.execute(
            script: script, submission: Self.solution("static int f(int x) { return \"oops\"; }"))
        #expect(result.code == 2, "a build failure must be an error, not a fail")
        #expect(result.stderr.contains("error"), "javac's diagnostic did not reach longResult")
    }

    // MARK: - approximateEquality

    @Test func approximateEqualityHonoursTolerance() throws {
        guard Self.javacAvailable else { return }
        let script = Self.render(Self.family(.approximateEquality, expected: .double(1.0)))
        let good = try Self.execute(
            script: script,
            submission: Self.solution("static double f(int x) { return 1.0000001; }"))
        #expect(good.code == 0, "inside tolerance failed: \(good.stdout) \(good.stderr)")

        let bad = try Self.execute(
            script: script, submission: Self.solution("static double f(int x) { return 2.0; }"))
        #expect(bad.code == 1, "outside tolerance passed: \(bad.stdout)")
    }

    // MARK: - unorderedEquality

    @Test func unorderedEqualityIgnoresOrder() throws {
        guard Self.javacAvailable else { return }
        let script = Self.render(
            Self.family(.unorderedEquality, expected: .array([.int(1), .int(2), .int(3)])))
        let good = try Self.execute(
            script: script,
            submission: Self.solution(
                "static java.util.List<Integer> f(int x) { return java.util.Arrays.asList(3, 1, 2); }"
            ))
        #expect(good.code == 0, "reordered list failed: \(good.stdout) \(good.stderr)")

        let bad = try Self.execute(
            script: script,
            submission: Self.solution(
                "static java.util.List<Integer> f(int x) { return java.util.Arrays.asList(1, 2); }"))
        #expect(bad.code == 1, "a short list passed: \(bad.stdout)")
    }

    // MARK: - returnTypeCheck

    @Test func returnTypeCheckMatchesNeutralNames() throws {
        guard Self.javacAvailable else { return }
        let script = Self.render(Self.family(.returnTypeCheck, expected: .string("str")))
        let good = try Self.execute(
            script: script, submission: Self.solution("static String f(int x) { return \"ok\"; }"))
        #expect(good.code == 0, "a String return did not match \"str\": \(good.stdout)")

        let bad = try Self.execute(
            script: script, submission: Self.solution("static int f(int x) { return 1; }"))
        #expect(bad.code == 1, "an int return matched \"str\": \(bad.stdout)")
        #expect(bad.stdout.contains("int"), "the failure did not name the type it got")
    }

    // MARK: - exceptionExpected

    @Test func exceptionExpectedMatchesOnTypeAndMessage() throws {
        guard Self.javacAvailable else { return }
        let script = Self.render(
            Self.family(.exceptionExpected, expected: .string("IllegalArgumentException")))
        let good = try Self.execute(
            script: script,
            submission: Self.solution(
                "static int f(int x) { throw new IllegalArgumentException(\"bad\"); }"))
        #expect(good.code == 0, "the expected exception did not pass: \(good.stdout) \(good.stderr)")

        let wrongKind = try Self.execute(
            script: script,
            submission: Self.solution("static int f(int x) { throw new IllegalStateException(\"x\"); }"))
        #expect(wrongKind.code == 1, "the wrong exception passed: \(wrongKind.stdout)")

        let noThrow = try Self.execute(
            script: script, submission: Self.solution("static int f(int x) { return 1; }"))
        #expect(noThrow.code == 1, "returning normally passed an exceptionExpected case")
        #expect(noThrow.stdout.contains("no error raised"))
    }

    // MARK: - performanceThreshold

    @Test func performanceThresholdTimesTheCall() throws {
        guard Self.javacAvailable else { return }
        let script = Self.render(Self.family(.performanceThreshold, expected: .int(5000)))
        let good = try Self.execute(
            script: script, submission: Self.solution("static int f(int x) { return x; }"))
        #expect(good.code == 0, "a fast method failed its budget: \(good.stdout) \(good.stderr)")

        let slow = Self.render(Self.family(.performanceThreshold, expected: .int(1)))
        let bad = try Self.execute(
            script: slow,
            submission: Self.solution(
                "static int f(int x) { try { Thread.sleep(200); } catch (Exception e) {} return x; }"
            ))
        #expect(bad.code == 1, "a 200ms method met a 1ms budget: \(bad.stdout)")
    }

    // MARK: - stdoutEquality

    @Test func stdoutEqualityComparesPrintedText() throws {
        guard Self.javacAvailable else { return }
        let script = Self.render(Self.family(.stdoutEquality, expected: .string("hello")))
        let good = try Self.execute(
            script: script,
            submission: Self.solution("static void f(int x) { System.out.println(\"hello\"); }"))
        #expect(good.code == 0, "matching output failed: \(good.stdout) \(good.stderr)")

        let bad = try Self.execute(
            script: script,
            submission: Self.solution("static void f(int x) { System.out.println(\"nope\"); }"))
        #expect(bad.code == 1, "mismatched output passed: \(bad.stdout)")
    }

    // MARK: - variableEquality

    @Test func variableEqualityReadsAStaticField() throws {
        guard Self.javacAvailable else { return }
        let family = Self.family(
            .variableEquality, function: "Solution.LIMIT", expected: .int(42))
        let script = Self.render(family)
        let good = try Self.execute(
            script: script, submission: Self.solution("static final int LIMIT = 42;"))
        #expect(good.code == 0, "the right value failed: \(good.stdout) \(good.stderr)")

        let bad = try Self.execute(
            script: script, submission: Self.solution("static final int LIMIT = 7;"))
        #expect(bad.code == 1, "the wrong value passed: \(bad.stdout)")
    }

    // MARK: - differential

    @Test func differentialComparesAgainstTheReference() throws {
        guard Self.javacAvailable else { return }
        let family = Self.family(
            .differential, expected: .null,
            // `ck_ref_Solution_f`, not `ck_ref_Solution.f`: the qualified target
            // is sanitized into a legal identifier — see
            // `PatternFamily.differentialReferenceName`.
            reference: "static int ck_ref_Solution_f(int x) { return x * 2; }")
        let script = Self.render(family)
        let good = try Self.execute(
            script: script, submission: Self.solution("static int f(int x) { return x + x; }"))
        #expect(good.code == 0, "an equivalent method failed: \(good.stdout) \(good.stderr)")

        let bad = try Self.execute(
            script: script, submission: Self.solution("static int f(int x) { return x; }"))
        #expect(bad.code == 1, "a divergent method passed: \(bad.stdout)")
    }

    // MARK: - Per-student inputs

    /// `_ck_inputs.java` is WRITTEN by the server and READ by the generated
    /// test — the leg the runbook warns is usually proved only in one
    /// direction. The file here is the real `renderInputsFile` output, not a
    /// fixture.
    @Test func aPerStudentInputReachesTheGeneratedTest() throws {
        guard Self.javacAvailable else { return }
        let family = PatternFamily(
            id: "fam", name: "Family", kind: .boundaryEquality,
            functionName: "Solution.f", paramNames: ["x"],
            defaults: PatternDefaults(tier: .pub, points: 1, hint: nil),
            cases: [
                PatternCase(
                    key: "01", label: "case", args: [.null], expected: .int(10),
                    argVarRefs: ["threshold"])
            ],
            referenceImplementation: nil)
        let script = Self.render(family, perStudent: ["threshold"])
        let inputs = AssignmentLanguage.java.renderInputsFile([
            "threshold": AssignmentLanguage.java.literal(.int(5))
        ])
        let result = try Self.execute(
            script: script,
            submission: Self.solution("static int f(int x) { return x * 2; }"),
            inputs: inputs)
        #expect(
            result.code == 0,
            """
            the per-student input did not reach the test (or did not type-check \
            at the call site): \(result.stdout) \(result.stderr)
            """)
    }

    // MARK: - The existence guard

    @Test func theExistenceGuardFailsOnAMissingMethod() throws {
        guard Self.javacAvailable else { return }
        let script = renderJavaExistenceGuard(
            family: Self.family(.boundaryEquality, expected: .int(6)), specHash: "h")

        let present = try Self.execute(
            script: script, submission: Self.solution("static int f(int x) { return 1; }"))
        #expect(present.code == 0, "a defined method failed the guard: \(present.stdout)")

        let missing = try Self.execute(
            script: script, submission: Self.solution("static int other(int x) { return 1; }"))
        #expect(missing.code == 1, "a missing method did not FAIL the guard: \(missing.stdout)")
        #expect(missing.stdout.contains("not defined"))
    }
}
