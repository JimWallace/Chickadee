// Tests/WorkerTests/CppNativeGradingTests.swift
//
// Native-worker grading of C++, run for real: a workspace assembled the way
// the runner assembles one (injected test_runtime.hpp, submission, student
// hint), generated-SHAPED .sh wrappers, and the actual
// UnsandboxedScriptRunner spawning /bin/sh -> g++ -> the binary through
// executeSuites. The C++ twin of Octave/LuaNativeGradingTests, guarding the
// same chain for the same reason: instructor validation is a NATIVE-worker
// job, so a broken native path means no C++ assignment can be validated at
// all. (The REAL renderer's bytes are executed in
// Tests/APITests/PatternFamilyRendererCppTests.swift — this suite pins the
// worker chain with wrappers of the same shape.)

import Core
import Foundation
import RunnerCore
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(3))) struct CppNativeGradingTests {

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

    /// The did-not-skip proof (audit F2). Every test below guards
    /// `gppAvailable` and returns silently when g++ is absent — right on a
    /// laptop, a silent hole in CI. Under `CI`, g++ MUST be present.
    @Test func gppIsPresentInCI() {
        guard ProcessInfo.processInfo.environment["CI"] != nil else { return }
        #expect(
            Self.gppAvailable,
            """
            g++ is absent in the CI image, so every native C++ grading test skipped \
            silently. Add it to .github/docker/ci-image/Dockerfile and the WorkerTests \
            apt fallback in swift-tests.yml.
            """)
    }

    /// A wrapper of the generated shape: student discovery via the hint
    /// file, heredoc source, single-TU compile, exec.
    static func wrapper(stem: String, body: String) -> String {
        """
        #!/bin/sh
        student_file=""
        if [ -f .chickadee_student_module ]; then
            student_file=$(cat .chickadee_student_module)
        fi
        if [ ! -f "$student_file" ]; then
            echo "No C++ submission file was found to grade." 1>&2
            exit 2
        fi
        cp "$student_file" .ck_solution.cpp
        cat > .ck_src_\(stem).cpp <<'CHICKADEE_GENERATED_SOURCE'
        #include "test_runtime.hpp"
        #define main ck_student_main
        #include ".ck_solution.cpp"
        #undef main
        int main() {
        \(body)
        }
        CHICKADEE_GENERATED_SOURCE
        g++ -std=c++20 -O0 .ck_src_\(stem).cpp -o .ck_bin_\(stem) 1>&2 || exit 2
        exec ./.ck_bin_\(stem)
        """ + "\n"
    }

    static func makeWorkspace(
        submission: String,
        scripts: [String: String]
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-cppnative-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // The SAME embedded source the worker injects, not a fixture copy —
        // so a runtime change that breaks native grading fails here.
        try testRuntimeSource(for: .cpp).write(
            to: dir.appendingPathComponent("test_runtime.hpp"), atomically: true, encoding: .utf8)
        try submission.write(
            to: dir.appendingPathComponent("solution.cpp"), atomically: true, encoding: .utf8)
        try "solution.cpp".write(
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

    /// The whole chain, pass case: compile the runtime + submission + test
    /// as one TU, run the binary, read the shortResult JSON off stdout.
    @Test func aCppTestIsGradedByTheNativeWorker() async throws {
        guard Self.gppAvailable else { return }

        let script = Self.wrapper(
            stem: "dbl",
            body: """
                    auto result = double_it(21);
                    if (!ck::equal(result, 42)) {
                        ck::failed("double_it(21) should be 42, got " + ck::format(result));
                    }
                    ck::passed("Returned " + ck::format(result));
                """)
        let dir = try Self.makeWorkspace(
            submission: "int double_it(int x) { return x * 2; }\n",
            scripts: ["publictest_dbl.sh": script])
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcomes = await Self.runSuites([Self.item("publictest_dbl.sh")], in: dir)
        let outcome = try #require(outcomes.first)
        #expect(
            outcome.status == TestStatus.pass,
            """
            Native C++ grading did not pass: \(outcome.status) — \(outcome.shortResult) \
            / \(outcome.longResult ?? ""). An error mentioning g++ means the compiler is \
            missing (the exit-127 class); anything else is the wrapper or the runtime.
            """)
        #expect(outcome.shortResult.contains("Returned 42"))
    }

    /// Exit 1 is a fail; a submission that does not compile is an error with
    /// the g++ diagnostic captured as longResult.
    @Test func failAndErrorMapThroughTheWrapper() async throws {
        guard Self.gppAvailable else { return }

        let script = Self.wrapper(
            stem: "dbl",
            body: """
                    auto result = double_it(21);
                    if (!ck::equal(result, 42)) {
                        ck::failed("wrong value");
                    }
                    ck::passed("ok");
                """)

        let wrongDir = try Self.makeWorkspace(
            submission: "int double_it(int x) { return x + 2; }\n",
            scripts: ["publictest_dbl.sh": script])
        defer { try? FileManager.default.removeItem(at: wrongDir) }
        let wrong = try #require(
            await Self.runSuites([Self.item("publictest_dbl.sh")], in: wrongDir).first)
        #expect(wrong.status == TestStatus.fail)
        #expect(wrong.shortResult.contains("wrong value"))

        let brokenDir = try Self.makeWorkspace(
            submission: "int double_it(int x) { return x * 2\n",
            scripts: ["publictest_dbl.sh": script])
        defer { try? FileManager.default.removeItem(at: brokenDir) }
        let broken = try #require(
            await Self.runSuites([Self.item("publictest_dbl.sh")], in: brokenDir).first)
        #expect(broken.status == TestStatus.error)
        #expect((broken.longResult ?? "").contains("error"))
    }

    /// A main-bearing submission (an intro "write a program" file) still has
    /// its functions graded — the wrapper's `#define main` rename.
    @Test func aMainBearingSubmissionStillExposesItsFunctions() async throws {
        guard Self.gppAvailable else { return }

        let script = Self.wrapper(
            stem: "m",
            body: """
                    if (!ck::equal(double_it(4), 8)) { ck::failed("wrong"); }
                    ck::passed("graded a main-bearing submission");
                """)
        let dir = try Self.makeWorkspace(
            submission: """
                #include <iostream>
                int double_it(int x) { return x * 2; }
                int main() {
                    std::cout << double_it(2) << "\\n";
                    return 0;
                }
                """,
            scripts: ["publictest_m.sh": script])
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = try #require(
            await Self.runSuites([Self.item("publictest_m.sh")], in: dir).first)
        #expect(outcome.status == TestStatus.pass, "got \(outcome.status): \(outcome.shortResult)")
    }

    /// The per-student inputs header — written through the real renderer,
    /// with a beyond-int32 value so the LL suffix is exercised — reads back
    /// through `ck_inputs::` in the same TU.
    @Test func perStudentInputsAreReadableOnTheNativePath() async throws {
        guard Self.gppAvailable else { return }

        let script = Self.wrapper(
            stem: "thr",
            body: """
                    if (!ck::equal(over(ck_inputs::threshold), true)) {
                        ck::failed("threshold comparison failed");
                    }
                    ck::passed("inputs delivered");
                """)
        // The wrapper's TU needs the include; splice it into the generated
        // source the same way the renderer does.
        let withInclude = script.replacingOccurrences(
            of: "#include \"test_runtime.hpp\"",
            with: "#include \"test_runtime.hpp\"\n#include \"_ck_inputs.hpp\"")

        let dir = try Self.makeWorkspace(
            submission: "bool over(long long x) { return x > 100; }\n",
            scripts: ["publictest_thr.sh": withInclude])
        defer { try? FileManager.default.removeItem(at: dir) }

        let language = AssignmentLanguage.cpp
        try language.renderInputsFile([
            "threshold": language.literal(.int(3_000_000_000))
        ]).write(
            to: dir.appendingPathComponent("_ck_inputs.hpp"), atomically: true, encoding: .utf8)

        let outcome = try #require(
            await Self.runSuites([Self.item("publictest_thr.sh")], in: dir).first)
        #expect(outcome.status == TestStatus.pass, "got \(outcome.status): \(outcome.shortResult)")
    }
}
