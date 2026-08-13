// Tests/WorkerTests/JavaNativeGradingTests.swift
//
// Java's generated tests, run through the REAL worker path: `scriptInvocation`
// → `NativeScriptExecutor` → `executeSuites` → `interpretScriptOutput`.
//
// WHY THIS SUITE HAS TO EXIST. Java is upload-only, so the native worker is not
// one of two grading paths — it is the only one. Lua, Octave, C++ and Racket
// each had a `*NativeGradingTests` and Java, the seventh and newest language,
// had none: the audit's F5 observation ("the asymmetry tracks recency")
// recurring for the language added after F5 was closed.
//
// `PatternFamilyRendererJavaTests` does run real javac/java, but through its own
// harness — it never touches `scriptInvocation`, `NativeScriptExecutor` or the
// shared suite loop, so nothing pinned that a generated Java case is dispatched
// and interpreted correctly by the worker.
//
// Modelled on `RacketNativeGradingTests` deliberately — same workspace shape,
// same did-not-skip proof — so the five read as one family.

import Core
import Foundation
import RunnerCore
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(5))) struct JavaNativeGradingTests {

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

    /// The did-not-skip proof. Every test below returns silently when the JDK is
    /// absent — correct on a laptop, a silent hole in CI, and precisely how a
    /// language ships with a suite that never runs.
    @Test func javacIsPresentInCI() {
        guard ProcessInfo.processInfo.environment["CI"] != nil else { return }
        #expect(
            Self.javacAvailable,
            """
            javac is absent in the CI image, so every native Java grading test skipped \
            silently. Note the probe is `javac`, not `java`: a JRE-only image passes the \
            latter and fails every test at compile time.
            """)
    }

    /// A workspace shaped like the one `RunnerDaemon` materializes: the injected
    /// runtime, the student's class, and the hint naming it.
    static func makeWorkspace(submission: String, scripts: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-javanative-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Reached through `runtimeHelperFiles(for:)` rather than the constant, so
        // this also proves the helper a Java workspace gets is the one the
        // installer loop writes.
        for (name, source) in runtimeHelperFiles(for: .java) {
            try source.write(
                to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try submission.write(
            to: dir.appendingPathComponent("Solution.java"), atomically: true, encoding: .utf8)
        try "Solution.java".write(
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
            items, timeLimitSeconds: 120, attemptNumber: 1, executor: executor)
    }

    static func item(_ script: String) -> SuiteItem {
        SuiteItem(script: script, tier: .pub, displayName: script, dependsOn: [], points: 1)
    }

    /// A generated Java case is a `.sh` wrapper, so this also pins that the
    /// wrapper's compile-and-run round trip survives the worker's dispatch —
    /// the thing `generatedScriptExtension: "sh"` makes true and no test said.
    @Test func aGeneratedJavaCaseIsGradedByTheNativeWorker() async throws {
        guard Self.javacAvailable else { return }

        // Written out rather than produced by `renderJavaPatternCase`: that
        // renderer lives in APIServer, which WorkerTests cannot import. The
        // shape is the generated one — quoted heredoc, javac with the runtime
        // named explicitly, then the sentinel check — and the renderer's own
        // bytes are covered by `JavaRendererExecutionTests` and the goldens.
        // What is under test here is the WORKER's half: dispatch, the suite
        // loop, and output interpretation.
        let script = """
            #!/bin/sh
            cat > CkTest_fam_01.java <<'CHICKADEE_GENERATED_SOURCE'
            public class CkTest_fam_01 {
                public static void main(String[] ckArgs) throws Exception {
                    var x = 3;
                    var result = Solution.f(x);
                    if (!ck.equal(result, 6)) {
                        ck.failed("wrong value");
                    }
                    ck.passed("Returned 6");
                }
            }
            CHICKADEE_GENERATED_SOURCE
            javac -encoding UTF-8 -cp . -d . CkTest_fam_01.java test_runtime.java 1>&2 || exit 2
            ck_out=$(java -ea -cp . CkTest_fam_01)
            ck_rc=$?
            if ! printf '%s\\n' "$ck_out" | grep -q '^CK_SENTINEL$'; then
                echo "The test did not run to completion." 1>&2
                exit 2
            fi
            printf '%s\\n' "$ck_out" | grep -v '^CK_SENTINEL$'
            exit $ck_rc
            """

        let dir = try Self.makeWorkspace(
            submission: "public class Solution { static int f(int x) { return x * 2; } }\n",
            scripts: ["publictest_fam_01.sh": script])
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcomes = await Self.runSuites([Self.item("publictest_fam_01.sh")], in: dir)
        let outcome = try #require(outcomes.first)
        #expect(
            outcome.status == .pass,
            """
            A generated Java case was not graded as a pass — status \(outcome.status), \
            stderr: \(outcome.longResult ?? "none").
            """)
        #expect(
            !outcome.shortResult.contains("CK_SENTINEL"),
            "the sentinel leaked into the student-visible result line")
    }

    /// The exit-code contract holds through javac + java + the wrapper's
    /// sentinel check, not just through the classifier.
    @Test func exitCodesMapToOutcomeStatuses() async throws {
        guard Self.javacAvailable else { return }

        func wrapper(_ verdict: String) -> String {
            """
            #!/bin/sh
            cat > CkProbe.java <<'CHICKADEE_GENERATED_SOURCE'
            public class CkProbe {
                public static void main(String[] a) { ck.\(verdict); }
            }
            CHICKADEE_GENERATED_SOURCE
            javac -encoding UTF-8 -cp . -d . CkProbe.java test_runtime.java 1>&2 || exit 2
            ck_out=$(java -ea -cp . CkProbe)
            ck_rc=$?
            printf '%s\\n' "$ck_out" | grep -v '^CK_SENTINEL$'
            exit $ck_rc
            """
        }

        let dir = try Self.makeWorkspace(
            submission: "public class Solution { static int f(int x) { return x; } }\n",
            scripts: [
                "publictest_pass.sh": wrapper(#"passed("ok")"#),
                "publictest_fail.sh": wrapper(#"failed("nope")"#),
                "publictest_error.sh": wrapper(#"errored("broken")"#),
            ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcomes = await Self.runSuites(
            [
                Self.item("publictest_pass.sh"),
                Self.item("publictest_fail.sh"),
                Self.item("publictest_error.sh"),
            ], in: dir)
        #expect(outcomes.count == 3)
        #expect(outcomes[0].status == .pass, "stderr: \(outcomes[0].longResult ?? "none")")
        #expect(outcomes[1].status == .fail)
        #expect(outcomes[2].status == .error)
        // The `errored` footer (#1349): an error's summary must be its own
        // message, not whatever the student happened to print last.
        #expect(
            outcomes[2].shortResult.contains("broken"),
            "the error's shortResult did not carry its message: \(outcomes[2].shortResult)")
    }

    /// A HAND-WRITTEN `.java` suite entry is a documented instructor path
    /// (`docs/java-support.md`), and nothing pinned that it dispatches to `java`
    /// single-file source mode rather than falling through to `/bin/sh`.
    @Test func aHandWrittenJavaScriptIsRunByTheJavaLauncher() async throws {
        guard Self.javacAvailable else { return }

        let dir = try Self.makeWorkspace(
            submission: "public class Solution { static int f(int x) { return x; } }\n",
            scripts: [
                "publictest_handwritten.java": """
                public class publictest_handwritten {
                    public static void main(String[] a) {
                        System.out.println("{\\"shortResult\\": \\"hand-written ok\\"}");
                    }
                }
                """
            ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcomes = await Self.runSuites([Self.item("publictest_handwritten.java")], in: dir)
        let outcome = try #require(outcomes.first)
        #expect(
            outcome.status == .pass,
            """
            A hand-written .java suite entry was not run by the java launcher — \
            status \(outcome.status), stderr: \(outcome.longResult ?? "none"). An `error` \
            with a shell complaint means it fell through to /bin/sh.
            """)
        #expect(outcome.shortResult == "hand-written ok")
    }
}
