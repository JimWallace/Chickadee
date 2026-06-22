// Tests/APITests/PatternFamilyFixtures.swift
//
// Free-function helpers replacing PatternFamilyTestCase.  The fixture
// helper `withPatternFamilyFixture { fixture in ... }` builds the
// app+setup pair and shuts it down deterministically.

import Core
import Crypto
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

// MARK: - Family fixtures

func pfBMIFamily(
    id: String = "bmi_category",
    hint: String? = "values below 18.5 should be 'underweight'",
    tier: TestTier = .pub
) -> PatternFamily {
    PatternFamily(
        id: id,
        name: "BMI Category Boundaries",
        kind: .boundaryEquality,
        functionName: "bmi_category",
        paramNames: ["bmi"],
        defaults: PatternDefaults(tier: tier, points: 1, hint: hint),
        cases: [
            PatternCase(
                key: "01", label: "BMI < 18.5 is underweight",
                args: [.double(18.49)], expected: .string("underweight")),
            PatternCase(
                key: "02", label: "BMI = 18.5 is normal",
                args: [.double(18.5)], expected: .string("normal")),
            PatternCase(
                key: "03", label: "BMI >= 30 is obese",
                args: [.double(30.0)], expected: .string("obese")),
        ]
    )
}

func pfApproxFamily(tolerance: Double? = 0.01) -> PatternFamily {
    PatternFamily(
        id: "bmi_kg_m2",
        name: "BMI numeric",
        kind: .approximateEquality,
        functionName: "bmi",
        paramNames: ["mass_kg", "height_m"],
        defaults: PatternDefaults(tier: .pub, points: 1, hint: nil, tolerance: tolerance),
        cases: [
            PatternCase(
                key: "01", label: "average adult",
                args: [.double(70.0), .double(1.75)], expected: .double(22.857)),
            PatternCase(
                key: "02", label: "tall adult",
                args: [.double(85.0), .double(1.90)], expected: .double(23.546)),
        ]
    )
}

func pfNotebookVariablesFamily() -> PatternFamily {
    PatternFamily(
        id: "notebook_variables",
        name: "Notebook Variables",
        kind: .variableEquality,
        functionName: "_",
        paramNames: ["variable"],
        defaults: PatternDefaults(
            tier: .pub, points: 1, hint: "Make sure you assigned the value to the variable with this exact name."),
        cases: [
            PatternCase(
                key: "01", label: "beats equals 5",
                args: [.string("beats")], expected: .int(5)),
            PatternCase(
                key: "02", label: "note_name equals A",
                args: [.string("note_name")], expected: .string("A")),
        ]
    )
}

func pfHelloPrintsFamily(expected: String = "hi world") -> PatternFamily {
    PatternFamily(
        id: "hello_prints",
        name: "Hello prints to stdout",
        kind: .stdoutEquality,
        functionName: "say_hi",
        paramNames: ["name"],
        cases: [
            PatternCase(
                key: "01", label: "prints greeting",
                args: [.string("world")], expected: .string(expected))
        ]
    )
}

// MARK: - Fixture plumbing

struct PFFixture {
    let app: Application
    let setup: APITestSetup
}

/// Builds the app + an APITestSetup pair, runs `body` against them, and
/// shuts the app down deterministically when the body returns.
func withPatternFamilyFixture(_ body: (PFFixture) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    let tmpDir = NSTemporaryDirectory() + "pattern-family-tests-\(UUID().uuidString)/"

    let fixture: PFFixture
    do {
        try await configureTestDatabase(app)

        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        app.testSetupsDirectory = tmpDir

        let courseID = UUID()
        let course = APICourse(
            id: courseID, code: "PF101", name: "Pattern Family Test", enrollmentMode: .auto)
        try await course.save(on: app.db)

        let zipPath = tmpDir + "\(UUID().uuidString).zip"
        try pfWriteEmptyZip(at: zipPath)

        let initialManifest = try makeWorkerManifestJSON(testSuites: [], includeMakefile: false)
        let setup = APITestSetup(
            id: "pf_test_\(UUID().uuidString.prefix(8))",
            manifest: initialManifest, zipPath: zipPath, courseID: courseID
        )
        try await setup.save(on: app.db)

        fixture = PFFixture(app: app, setup: setup)
    } catch {
        // Same SIGILL guard as `makeTestingApplication`: any throw before
        // the fixture is fully built leaves a half-initialized Application
        // that crashes in its sync deinit.  Shutdown explicitly first.
        try? FileManager.default.removeItem(atPath: tmpDir)
        try? await app.asyncShutdown()
        throw error
    }

    do {
        try await body(fixture)
        try? FileManager.default.removeItem(atPath: tmpDir)
        try await app.asyncShutdown()
    } catch {
        try? FileManager.default.removeItem(atPath: tmpDir)
        try? await app.asyncShutdown()
        throw error
    }
}

func pfWriteEmptyZip(at path: String) throws {
    let fm = FileManager.default
    let stagingDir = fm.temporaryDirectory
        .appendingPathComponent("empty-zip-staging-\(UUID().uuidString)")
    try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: stagingDir) }
    // zip needs at least one entry to produce a valid archive.
    try Data("placeholder".utf8).write(to: stagingDir.appendingPathComponent(".placeholder"))
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = stagingDir
    zip.arguments = ["-q", "-r", path, "."]
    zip.standardOutput = Pipe()
    zip.standardError = Pipe()
    try zip.run()
    zip.waitUntilExit()
    #expect(zip.terminationStatus == 0)
}

func pfManifestCacheMaterial(_ setup: APITestSetup) throws -> String {
    // Mirror the shape the runner uses at RunnerDaemon.swift:1110-1116:
    //   hash(testSetupID + url + manifestBytes)
    // Using manifest bytes alone is enough to prove invalidation here.
    let digest = SHA256.hash(data: Data(setup.manifest.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

func pfDecodeManifest(_ json: String) throws -> TestProperties {
    try JSONDecoder().decode(TestProperties.self, from: Data(json.utf8))
}

/// Deterministic filename of a function-calling family's auto-existence
/// guard (Phase 1).  Mirrors `existenceGuard` / `generatedScriptFilename`,
/// so order/diff assertions can reference the guard without hard-coding the
/// `_exists` convention in every test.
func pfGuardFilename(_ familyID: String, tier: TestTier = .pub) -> String {
    generatedScriptFilename(familyID: familyID, caseKey: patternExistenceGuardCaseKey, tier: tier)
}

func pfAssertValidPythonSyntax(_ source: String, label: String) throws {
    // python3 is required to parse-check the generated source.  On a host
    // without it, skip silently rather than trapping: `/usr/bin/env python3`
    // launches env, env exits 127, and a non-throwing write to the now-closed
    // stdin pipe traps (broken pipe) → SIGILL, taking down the whole test
    // process.  CI installs python3; this guard only protects bare dev hosts.
    let python3Paths = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
    guard python3Paths.contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
        return  // python3 unavailable on this platform — skip the syntax check
    }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", "-c", "import ast, sys; ast.parse(sys.stdin.read())"]
    let stdin = Pipe()
    let stderr = Pipe()
    p.standardInput = stdin
    p.standardError = stderr
    p.standardOutput = Pipe()
    try p.run()
    // Throwing write/close (not the non-throwing `write(_:)`, whose internal
    // `try!` traps on a broken pipe) so a failed subprocess surfaces as a
    // thrown error instead of a SIGILL.
    try stdin.fileHandleForWriting.write(contentsOf: Data(source.utf8))
    try stdin.fileHandleForWriting.close()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        Issue.record("Generated source for \(label) is not valid Python:\n\(err)\n--- source ---\n\(source)")
    }
}

/// Runtime outcome of executing a generated pattern-family case body.
enum PFGeneratedOutcome: Equatable { case pass, fail, error }

/// Executes a generated case `body` the way the runner would: in a workspace
/// holding an optional `_ck_inputs.py` (exactly what
/// `RunnerDaemon+JobProcessing` / `browser-runner.js` write from the resolved
/// per-student values) and a `student_module` exposing `student`'s functions,
/// with test_runtime's `passed()` / `failed()` stubbed to sentinels and cwd
/// set to the workspace (so the preamble's relative `_ck_inputs.py` load
/// resolves).  Returns whether the case passed, failed, or errored — letting a
/// test assert the per-student preamble actually *grades*, not merely parses.
func pfRunGeneratedCase(
    body: String, ckInputs: String?, student: String
) throws -> PFGeneratedOutcome {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("pf_run_\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    if let ckInputs {
        try ckInputs.write(to: dir.appendingPathComponent("_ck_inputs.py"), atomically: true, encoding: .utf8)
    }
    try student.write(to: dir.appendingPathComponent("_student.py"), atomically: true, encoding: .utf8)
    try body.write(to: dir.appendingPathComponent("_case.py"), atomically: true, encoding: .utf8)

    // Mirrors test_runtime's pass/fail dispatch with sentinels we can catch,
    // and binds `student_module` the way the runner's bootstrap does.
    let driver = """
        import types
        class _P(Exception): pass
        class _F(Exception): pass
        def passed(msg=""):
            print("OUTCOME:PASS"); raise _P()
        def failed(msg=""):
            print("OUTCOME:FAIL"); raise _F()
        student_module = types.ModuleType("student_module")
        with open("_student.py") as _f:
            exec(_f.read(), student_module.__dict__)
        try:
            with open("_case.py") as _f:
                exec(_f.read())
        except (_P, _F):
            pass
        """

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", "-c", driver]
    p.currentDirectoryURL = dir
    let out = Pipe()
    let err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try p.run()
    p.waitUntilExit()
    let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if stdout.contains("OUTCOME:PASS") { return .pass }
    if stdout.contains("OUTCOME:FAIL") { return .fail }
    let stderrText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    Issue.record(
        "Generated case neither passed nor failed:\nstdout=\(stdout)\nstderr=\(stderrText)\n--- body ---\n\(body)")
    return .error
}
