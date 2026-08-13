// Tests/WorkerTests/ProtectedWorkspaceFilenameTests.swift
//
// A student's upload must not be able to replace the tests it is graded by.
//
// The runner executes `manifest.testSuites[].script` out of the same directory
// the submission is merged into, and the merge wrote every student file by its
// own name over whatever was there. Generated names are deterministic
// (`{tier}test_{familyID}_{caseKey}.{ext}`) and public-tier ones are visible to
// students, so a zip carrying `publictest_bmi_01.py` replaced the instructor's
// test and was graded against itself. The submit form accepts `.zip`, so this
// was reachable from the ordinary student path (#1357).

import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite struct ProtectedWorkspaceFilenameTests {

    private static func manifest(
        scripts: [String], requiredFiles: [String] = []
    )
        -> TestProperties
    {
        TestProperties(
            requiredFiles: requiredFiles,
            testSuites: scripts.map { TestSuiteEntry(tier: .pub, script: $0) },
            timeLimitSeconds: 10
        )
    }

    private static func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-protected-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func theSuitesScriptsAndRuntimeHelpersAreProtected() {
        let names = protectedWorkspaceFilenames(
            manifest: Self.manifest(scripts: ["publictest_bmi_01.py", "test_manual.sh"]))
        #expect(names.contains("publictest_bmi_01.py"))
        #expect(names.contains("test_manual.sh"))
        #expect(names.contains("test_runtime.py"), "the runtime helpers are not protected")
        #expect(names.contains("sitecustomize.py"))
        #expect(names.contains("_ck_inputs.py"))
        #expect(names.contains(".chickadee_student_module"))
    }

    /// `requiredFiles` names what the student must SUPPLY. Protecting those
    /// would refuse every correct submission, so the guard must not.
    @Test func requiredFilesAreNotProtected() {
        let names = protectedWorkspaceFilenames(
            manifest: Self.manifest(scripts: ["publictest_a.py"], requiredFiles: ["warmup.py"]))
        #expect(!names.contains("warmup.py"), "a file the student must submit was refused")
    }

    /// The merge is the exploit path: a zip carrying a graded script's name.
    @Test func aStudentFileCannotOverwriteAGradedScript() throws {
        let source = try Self.directory()
        let destination = try Self.directory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        try "INSTRUCTOR TEST".write(
            to: destination.appendingPathComponent("publictest_bmi_01.py"),
            atomically: true, encoding: .utf8)
        try "print('always passes')".write(
            to: source.appendingPathComponent("publictest_bmi_01.py"),
            atomically: true, encoding: .utf8)
        try "def classify_bmi(x): return 'ok'".write(
            to: source.appendingPathComponent("solution.py"), atomically: true, encoding: .utf8)

        let refused = try mergeDirectoryContents(
            from: source,
            into: destination,
            protected: protectedWorkspaceFilenames(
                manifest: Self.manifest(scripts: ["publictest_bmi_01.py"])))

        #expect(refused == ["publictest_bmi_01.py"], "the collision was not reported")
        let surviving = try String(
            contentsOf: destination.appendingPathComponent("publictest_bmi_01.py"),
            encoding: .utf8)
        #expect(
            surviving == "INSTRUCTOR TEST",
            "the student's file replaced the instructor's test")
        #expect(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("solution.py").path),
            "the student's legitimate file was dropped along with the refused one")
    }

    /// The collision that matters is the one landing on a path the runner
    /// executes. A student's own file in a subdirectory is not that, and
    /// refusing it would be over-blocking.
    @Test func aNestedFileOfTheSameNameIsStillCopied() throws {
        let source = try Self.directory()
        let destination = try Self.directory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        let nested = source.appendingPathComponent("helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "mine".write(
            to: nested.appendingPathComponent("publictest_bmi_01.py"),
            atomically: true, encoding: .utf8)

        let refused = try mergeDirectoryContents(
            from: source,
            into: destination,
            protected: protectedWorkspaceFilenames(
                manifest: Self.manifest(scripts: ["publictest_bmi_01.py"])))

        #expect(refused.isEmpty, "a nested file was refused: \(refused)")
        #expect(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("helpers/publictest_bmi_01.py").path))
    }
}
