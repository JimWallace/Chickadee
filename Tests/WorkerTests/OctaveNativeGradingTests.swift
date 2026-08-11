// Tests/WorkerTests/OctaveNativeGradingTests.swift
//
// Native-worker grading of Octave, run for real: a workspace assembled the way
// the runner assembles one, generated-shaped `.m` tests, and the actual
// `UnsandboxedScriptRunner` spawning `env octave-cli` through `executeSuites`.
// The Octave twin of LuaNativeGradingTests, guarding the same chain for the
// same reason: instructor validation is a NATIVE-worker job even for
// browser-graded assignments, so a broken native path means no Octave
// assignment can be validated at all (the exit-127 class).

import Core
import Foundation
import RunnerCore
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(3))) struct OctaveNativeGradingTests {

    static var octaveAvailable: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["octave-cli", "--version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The did-not-skip proof for the WorkerTests job (audit F2). Every test
    /// below guards `octaveAvailable` and returns silently when Octave is
    /// absent — right on a laptop, a silent hole in CI. Under `CI`, Octave MUST
    /// be present; this cannot be satisfied by skipping.
    @Test func octaveIsPresentInCI() {
        guard ProcessInfo.processInfo.environment["CI"] != nil else { return }
        #expect(
            Self.octaveAvailable,
            """
            octave is absent in the CI image, so every native Octave grading test skipped \
            silently. Add it to .github/docker/ci-image/Dockerfile and the WorkerTests apt \
            fallback in swift-tests.yml.
            """)
    }

    /// A grading workspace shaped like the one `RunnerDaemon` materializes:
    /// the injected runtime, the student's submission, and the hint file.
    static func makeWorkspace(
        submission: String,
        scripts: [String: String]
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-octnative-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // The SAME embedded source the worker injects, not a fixture copy — so
        // a runtime change that breaks native grading fails here.
        try testRuntimeSource(for: .octave).write(
            to: dir.appendingPathComponent("test_runtime.m"), atomically: true, encoding: .utf8)
        try submission.write(
            to: dir.appendingPathComponent("solution.m"), atomically: true, encoding: .utf8)
        try "solution.m".write(
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

    /// A `.m` test is dispatched to a real interpreter and comes back with a
    /// status, not a command-not-found error.
    @Test func anOctaveTestIsGradedByTheNativeWorker() async throws {
        guard Self.octaveAvailable else { return }

        let passing = """
            chickadee = test_runtime();
            student = chickadee.load_student();
            target = chickadee.require_fn(student, "double_it");
            result = target(21);
            if !chickadee.equal(result, 42)
                chickadee.failed("double_it(21) should be 42");
            end
            chickadee.passed(["Returned " chickadee.format(result)]);
            """
        let dir = try Self.makeWorkspace(
            submission: "function r = double_it(x)\n  r = x * 2;\nend\n",
            scripts: ["publictest_double.m": passing])
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcomes = await Self.runSuites([Self.item("publictest_double.m")], in: dir)
        let outcome = try #require(outcomes.first)
        #expect(
            outcome.status == .pass,
            """
            Native Octave grading did not pass: \(outcome.status) — \(outcome.shortResult). \
            An `error` with a command-not-found message means `octave-cli` is missing from the \
            environment, which is the exit-127 defect: instructor validation of an Octave \
            assignment cannot pass, browser-graded or not.
            """)
        #expect(outcome.shortResult.contains("Returned 42"))
    }

    /// Exit 1 is a fail and exit 2 is an error, through the real subprocess
    /// boundary — the mapping generated Octave relies on when it calls
    /// `chickadee.failed` / `chickadee.errored`.
    @Test func exitCodesMapToOutcomeStatuses() async throws {
        guard Self.octaveAvailable else { return }

        let dir = try Self.makeWorkspace(
            submission: "x = 1;\n",
            scripts: [
                "publictest_fails.m": """
                chickadee = test_runtime();
                chickadee.failed("wrong value");
                """,
                "publictest_errors.m": """
                chickadee = test_runtime();
                chickadee.errored("could not set up");
                """,
            ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcomes = await Self.runSuites(
            [Self.item("publictest_errors.m"), Self.item("publictest_fails.m")], in: dir)
        let byName = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.testName, $0) })

        let failed = try #require(byName.values.first { $0.shortResult.contains("wrong value") })
        #expect(failed.status == .fail)
        let errored = try #require(
            byName.values.first { $0.shortResult.contains("could not set up") })
        #expect(errored.status == .error)
    }

    /// A submission whose own top-level code raises still has the functions it
    /// defined BEFORE the error graded — `chickadee.load_student()` tolerates
    /// the runtime error deliberately. (A smaller promise than R's
    /// expression-by-expression loader, which also keeps definitions after the
    /// error; the runtime's header states the difference.)
    @Test func aSubmissionThatRaisesAtTopLevelStillExposesItsFunctions() async throws {
        guard Self.octaveAvailable else { return }

        let script = """
            chickadee = test_runtime();
            student = chickadee.load_student();
            target = chickadee.require_fn(student, "double_it");
            if !chickadee.equal(target(4), 8)
                chickadee.failed("double_it(4) should be 8");
            end
            chickadee.passed("ok");
            """
        let dir = try Self.makeWorkspace(
            submission: """
                function r = double_it(x)
                  r = x * 2;
                end
                error("this line blows up after the function is defined");
                """,
            scripts: ["publictest_double.m": script])
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcomes = await Self.runSuites([Self.item("publictest_double.m")], in: dir)
        let outcome = try #require(outcomes.first)
        #expect(outcome.status == .pass, "got \(outcome.status): \(outcome.shortResult)")
    }

    /// The extractor→runtime round trip: `extractOctave` writes the marker
    /// lines and `chickadee.student_cells()` splits on them — executed under
    /// the real interpreter, because the two live in different files (Swift
    /// and test_runtime.m) with only this to hold them together.
    @Test func extractedNotebookCellsRoundTripThroughStudentCells() async throws {
        guard Self.octaveAvailable else { return }

        let extracted = extractOctave(
            cells: [
                NotebookCell(cellType: "code", source: "threshold = 10;"),
                NotebookCell(cellType: "markdown", source: "notes"),
                NotebookCell(
                    cellType: "code",
                    source: "function r = classify(x)\n  r = x > 0;\nend"),
            ],
            filename: "lab.ipynb")

        let script = """
            chickadee = test_runtime();
            cells = chickadee.student_cells();
            if numel(cells) != 2
                chickadee.failed(sprintf("expected 2 cells, got %d", numel(cells)));
            end
            if isempty(strfind(cells{1}, "threshold"))
                chickadee.failed("cell 1 lost its source");
            end
            chickadee.passed("cells round-tripped");
            """
        let dir = try Self.makeWorkspace(
            submission: extracted.source, scripts: ["publictest_cells.m": script])
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcomes = await Self.runSuites([Self.item("publictest_cells.m")], in: dir)
        let outcome = try #require(outcomes.first)
        #expect(outcome.status == .pass, "got \(outcome.status): \(outcome.shortResult)")
    }

    /// The per-student inputs file, written and read on the native path — with
    /// a null inside a collection, the case that needs `NA` to occupy its slot.
    @Test func perStudentInputsAreReadableOnTheNativePath() async throws {
        guard Self.octaveAvailable else { return }

        let script = """
            chickadee = test_runtime();
            values = chickadee.inputs();
            if !isKey(values, "threshold") || values("threshold") != 42
                chickadee.failed("threshold was missing or wrong");
            end
            holes = values("holes");
            if numel(holes) != 3 || !isnan(holes(2))
                chickadee.failed("holes did not survive the null");
            end
            chickadee.passed("inputs delivered");
            """
        let dir = try Self.makeWorkspace(
            submission: "x = 1;\n", scripts: ["publictest_inputs.m": script])
        defer { try? FileManager.default.removeItem(at: dir) }

        // Exactly what AssignmentLanguage.octave.renderInputsFile produces,
        // written through the real renderer rather than a fixture copy.
        let language = AssignmentLanguage.octave
        try language.renderInputsFile([
            "threshold": language.literal(.int(42)),
            "holes": language.literal(.array([.int(60), .null, .int(20)])),
        ]).write(
            to: dir.appendingPathComponent("_ck_inputs.m"), atomically: true, encoding: .utf8)

        let outcomes = await Self.runSuites([Self.item("publictest_inputs.m")], in: dir)
        let outcome = try #require(outcomes.first)
        #expect(outcome.status == .pass, "got \(outcome.status): \(outcome.shortResult)")
    }
}
