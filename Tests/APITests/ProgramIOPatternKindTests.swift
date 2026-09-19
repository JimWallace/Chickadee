// Tests/APITests/ProgramIOPatternKindTests.swift
//
// The `.programIO` pattern kind: a whole submission run as a program with a
// case's stdin text, graded on what it printed. Validation (the one-string-arg
// contract, the empty-needle and Lua-regex refusals), the Python rendering, and
// the Python rendering EXECUTED under the same bootstrap the runner uses —
// against unguarded scripts, `__main__`-guarded ones, programs that exit after
// their answer, and programs that crash.

import Core
import ChickadeeTestSupport
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct ProgramIOPatternKindTests {

    static func family(
        stdin: String = "3\n4\n", expected: JSONValue = .string("7"),
        comparison: ProgramIOComparison? = nil, args: [JSONValue]? = nil
    ) -> PatternFamily {
        PatternFamily(
            id: "io", name: "Adds two numbers", kind: .programIO,
            functionName: "", paramNames: ["stdin"],
            cases: [
                PatternCase(
                    key: "01", label: "sum", args: args ?? [.string(stdin)], expected: expected)
            ],
            ioComparison: comparison)
    }

    // MARK: - Validation

    @Test func acceptsAnEmptyExpectedUnderExact() throws {
        // "The program prints nothing" is a real case.
        try validatePatternFamilies([Self.family(expected: .string(""))], testSuites: [], language: .python)
    }

    @Test func acceptsEmptyStdin() throws {
        try validatePatternFamilies([Self.family(stdin: "")], testSuites: [], language: .python)
    }

    @Test func rejectsMoreThanOneArg() throws {
        let bad = Self.family(args: [.string("3\n"), .string("4\n")])
        #expect(throws: (any Error).self) {
            try validatePatternFamilies([bad], testSuites: [], language: .python)
        }
    }

    @Test func rejectsANonStringStdin() throws {
        let bad = Self.family(args: [.int(3)])
        #expect(throws: (any Error).self) {
            try validatePatternFamilies([bad], testSuites: [], language: .python)
        }
    }

    @Test func rejectsANonStringExpected() throws {
        let bad = Self.family(expected: .int(7))
        #expect(throws: (any Error).self) {
            try validatePatternFamilies([bad], testSuites: [], language: .python)
        }
    }

    @Test func rejectsAnEmptyNeedleForIncludedAndRegex() throws {
        for comparison in [ProgramIOComparison.included, .regex] {
            let bad = Self.family(expected: .string(""), comparison: comparison)
            #expect(throws: (any Error).self, "\(comparison) accepted an empty needle") {
                try validatePatternFamilies([bad], testSuites: [], language: .python)
            }
        }
    }

    @Test func rejectsRegexOnLua() throws {
        let fam = Self.family(expected: .string("^7$"), comparison: .regex)
        #expect(throws: (any Error).self) {
            try validatePatternFamilies([fam], testSuites: [], language: .lua)
        }
        try validatePatternFamilies([fam], testSuites: [], language: .python)
    }

    @Test func rejectsAnUnbalancedRegex() throws {
        let bad = Self.family(expected: .string("(7"), comparison: .regex)
        #expect(throws: (any Error).self) {
            try validatePatternFamilies([bad], testSuites: [], language: .python)
        }
    }

    // MARK: - Shape

    @Test func rendersOneRunnableScriptPerCase() throws {
        let rendered = renderPatternFamily(Self.family(), language: .python)
        #expect(rendered.count == 1)
        let script = try #require(rendered.first)
        #expect(script.filename == "publictest_io_01.py")
        #expect(script.source.hasPrefix("# Test: sum\n"))
        #expect(script.source.contains("_runpy.run_path("))
        #expect(script.source.contains("_builtins.input = _fed_input"))
        #expect(script.source.contains("stdin_text = \"3\\n4\\n\""))
        try pfAssertValidPythonSyntax(script.source, label: script.filename)
    }

    @Test func comparisonSelectsTheCheckAndNamesItselfToTheStudent() throws {
        let included = try #require(
            renderPatternFamily(Self.family(comparison: .included), language: .python).first)
        #expect(included.source.contains("_ok = expected in actual"))
        #expect(included.source.contains("output containing "))
        let regex = try #require(
            renderPatternFamily(Self.family(comparison: .regex), language: .python).first)
        #expect(regex.source.contains("_re.search(expected, actual, _re.MULTILINE)"))
        #expect(regex.source.contains("output matching "))
    }

    @Test func noExistenceGuardIsGenerated() throws {
        // Nothing is called by name, so there is nothing to guard.
        #expect(existenceGuard(for: Self.family(), language: .python) == nil)
        let names = patternFamilyAllGeneratedFilenames(Self.family(), language: .python)
        #expect(names == ["publictest_io_01.py"])
    }

    @Test func specHashTracksTheComparison() throws {
        #expect(patternFamilySpecHash(Self.family()) != patternFamilySpecHash(Self.family(comparison: .regex)))
    }

    @Test func ioComparisonRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(Self.family(comparison: .included))
        let decoded = try JSONDecoder().decode(PatternFamily.self, from: data)
        #expect(decoded.ioComparison == .included)
        #expect(decoded.resolvedIOComparison == .included)
        #expect(Self.family().resolvedIOComparison == .exact)
    }
}

/// The Python rendering executed the way the runner executes it: the same
/// bootstrap shape (`test_runtime` bound into builtins, the student module
/// loaded, `runpy` on the test), against real programs.
@Suite(.timeLimit(.minutes(3))) struct ProgramIOPythonExecutionTests {

    static var pythonAvailable: Bool {
        get async { await toolIsAvailable("python3", arguments: ["--version"]) }
    }

    /// The did-not-skip proof for the APITests job.
    @Test func pythonIsPresentInCI() {
        guard ProcessInfo.processInfo.environment["CI"] != nil else { return }
        #expect(Self.pythonAvailable, "python3 absent: every program-I/O execution test skipped silently")
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // APITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    /// Mirrors the runner's `pythonBootstrap`: helpers into builtins, the
    /// student module loaded (which is where an unguarded program first runs),
    /// then the test under `runpy`.
    private static let bootstrap = """
        import builtins, runpy, sys
        import test_runtime as _tr
        builtins.passed = _tr.passed
        builtins.failed = _tr.failed
        builtins.errored = _tr.errored
        builtins.require_function = _tr.require_function
        builtins.student_module = _tr.load_student_module()
        sys.argv = sys.argv[1:]
        runpy.run_path(sys.argv[0], run_name="__main__")
        """

    static func grade(
        _ family: PatternFamily, program: String
    ) throws -> (code: Int32, stdout: String) {
        let script = try #require(renderPatternFamily(family, language: .python).first)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-programio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let support = repoRoot.appendingPathComponent("Tools/runner-support")
        try FileManager.default.copyItem(
            at: support.appendingPathComponent("test_runtime.py"),
            to: dir.appendingPathComponent("test_runtime.py"))
        try program.write(to: dir.appendingPathComponent("prog.py"), atomically: true, encoding: .utf8)
        try "prog.py".write(
            to: dir.appendingPathComponent(".chickadee_student_module"), atomically: true, encoding: .utf8)
        try script.source.write(
            to: dir.appendingPathComponent(script.filename), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", bootstrap, script.filename]
        process.currentDirectoryURL = dir
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static let unguardedSum = "a = int(input())\nb = int(input())\nprint(a + b)\n"

    @Test func anUnguardedProgramReadingInputPassesAndFails() async throws {
        guard Self.pythonAvailable else { return }
        let family = ProgramIOPatternKindTests.family()
        let good = try Self.grade(family, program: Self.unguardedSum)
        #expect(good.code == 0, Comment(rawValue: good.stdout))
        let bad = try Self.grade(family, program: "a = int(input())\nb = int(input())\nprint(a * b)\n")
        #expect(bad.code == 1)
        #expect(bad.stdout.contains(GeneratedMessage.wrongOutput))
        #expect(bad.stdout.contains("'12'"))
    }

    /// The bootstrap imports the submission before the test runs. That import
    /// must neither block on the real stdin nor leak the program's output into
    /// the test's — the first line of stdout is the verdict's, not the
    /// program's.
    @Test func theBootstrapImportOfAnUnguardedProgramLeaksNothing() async throws {
        guard Self.pythonAvailable else { return }
        let family = ProgramIOPatternKindTests.family(expected: .string("8"))
        let result = try Self.grade(family, program: "print('banner')\n" + Self.unguardedSum)
        #expect(result.code == 1)
        #expect(result.stdout.hasPrefix(GeneratedMessage.wrongOutput), Comment(rawValue: result.stdout))
        #expect(result.stdout.contains("'banner\\n7'"))
    }

    @Test func aMainGuardedProgramRuns() async throws {
        guard Self.pythonAvailable else { return }
        let family = ProgramIOPatternKindTests.family()
        let program = """
            def main():
                a = int(input())
                b = int(input())
                print(a + b)

            if __name__ == "__main__":
                main()

            """
        #expect(try Self.grade(family, program: program).code == 0)
    }

    @Test func promptsArePartOfTheOutputAsOnATerminal() async throws {
        guard Self.pythonAvailable else { return }
        let program = "a = int(input('A: '))\nb = int(input('B: '))\nprint(a + b)\n"
        let exact = ProgramIOPatternKindTests.family(expected: .string("A: B: 7"))
        #expect(try Self.grade(exact, program: program).code == 0)
        let included = ProgramIOPatternKindTests.family(expected: .string("7"), comparison: .included)
        #expect(try Self.grade(included, program: program).code == 0)
    }

    @Test func regexComparisonMatchesAcrossLines() async throws {
        guard Self.pythonAvailable else { return }
        let family = ProgramIOPatternKindTests.family(expected: .string("^sum=7$"), comparison: .regex)
        let program = "a = int(input())\nb = int(input())\nprint('header')\nprint(f'sum={a + b}')\n"
        #expect(try Self.grade(family, program: program).code == 0)
        #expect(try Self.grade(family, program: "print('sum=8')\n").code == 1)
    }

    @Test func aProgramThatExitsAfterItsAnswerIsStillGraded() async throws {
        guard Self.pythonAvailable else { return }
        let family = ProgramIOPatternKindTests.family()
        let good = try Self.grade(
            family, program: "import sys\nprint(int(input()) + int(input()))\nsys.exit(0)\n")
        #expect(good.code == 0, Comment(rawValue: good.stdout))
        let bad = try Self.grade(family, program: "import sys\nprint(0)\nsys.exit(0)\n")
        #expect(bad.code == 1, "a sys.exit(0) after a wrong answer read as a pass: \(bad.stdout)")
    }

    @Test func aCrashIsAGradedFailureCarryingTheError() async throws {
        guard Self.pythonAvailable else { return }
        let family = ProgramIOPatternKindTests.family()
        let crashed = try Self.grade(family, program: "print(1 / 0)\n")
        #expect(crashed.code == 1)
        #expect(crashed.stdout.contains(GeneratedMessage.unexpectedException))
        #expect(crashed.stdout.contains("ZeroDivisionError"))
    }

    @Test func readingPastTheInputIsAGradedFailure() async throws {
        guard Self.pythonAvailable else { return }
        let family = ProgramIOPatternKindTests.family(stdin: "3\n")
        let starved = try Self.grade(family, program: Self.unguardedSum)
        #expect(starved.code == 1)
        #expect(starved.stdout.contains("EOFError"))
    }

    @Test func trailingWhitespaceIsIgnoredUnderExact() async throws {
        guard Self.pythonAvailable else { return }
        let family = ProgramIOPatternKindTests.family(expected: .string("7"))
        #expect(try Self.grade(family, program: "print('7  ')\nprint()\nprint()\n").code == 0)
    }
}
