import XCTest
@testable import chickadee_runner
import Core
import Foundation

// MARK: - Runner Working-Directory Setup Tests
//
// These tests verify that the runner arranges files correctly in the working
// directory before test execution.  They cover every combination of:
//
//   • Normal assignment (has starter notebook + solution notebook)
//   • Marmoset-imported assignment (Python test scripts, canonical .ipynb or .py)
//   • Marmoset import with no starter notebook
//   • Student submission (named same as starter notebook)
//   • Initial validation flow
//   • Edit/save re-validation flow (same runner behavior, different server path)
//
// The key invariant: after setup, the working directory must contain exactly
// ONE grading target (the student or canonical submission) and zero template
// notebooks that could confuse grading scripts.

final class RunnerWorkDirTests: XCTestCase {

    private var workDir: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        workDir = fm.temporaryDirectory
            .appendingPathComponent("chickadee-workdir-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: workDir)
    }

    // MARK: - Helpers

    /// Minimal valid notebook JSON.
    private let minimalNotebook = """
    {
      "nbformat": 4,
      "metadata": {"kernelspec": {"name": "python3"}},
      "cells": [{"cell_type": "code", "source": ["x = 1"]}]
    }
    """

    /// Notebook with a specific function definition for duplicate-detection tests.
    private func notebook(defining functionName: String) -> String {
        """
        {
          "nbformat": 4,
          "metadata": {"kernelspec": {"name": "python3"}},
          "cells": [{"cell_type": "code", "source": ["def \(functionName)():\\n", "    return 42"]}]
        }
        """
    }

    private func writeFile(_ content: String, name: String) throws {
        let url = workDir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func fileExists(_ name: String) -> Bool {
        fm.fileExists(atPath: workDir.appendingPathComponent(name).path)
    }

    private func readFile(_ name: String) throws -> String {
        try String(contentsOf: workDir.appendingPathComponent(name))
    }

    private func listFiles() throws -> Set<String> {
        let items = try fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
        return Set(items.map { $0.lastPathComponent })
    }

    /// Simulates the runner's working-directory setup:
    ///   1. Lay out test setup files (scripts, support files, optional starter notebook)
    ///   2. Copy the submission into the directory
    ///   3. Remove the starter notebook (if manifest says so and submission != starter)
    ///   4. Run extractNotebooksToCode
    ///   5. Write student module hint
    ///
    /// This mirrors RunnerDaemon.process() lines 143–168 without network I/O.
    private func simulateRunnerSetup(
        setupFiles: [(name: String, content: String)],
        submissionFilename: String?,
        submissionContent: String,
        manifest: TestProperties
    ) throws {
        // 1. Write test setup files (simulates unzipping the test setup zip)
        for file in setupFiles {
            try writeFile(file.content, name: file.name)
        }

        // 2. Copy submission (simulates the raw-file or unzip path)
        if let filename = submissionFilename {
            // Raw file submission — runner copies as-is
            let dest = workDir.appendingPathComponent(filename)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try submissionContent.write(to: dest, atomically: true, encoding: .utf8)
        }
        // (zip submissions would unzip into workDir; not tested here since the
        // arrangement is the same after extraction)

        // 3. Remove starter notebook (defaults to "assignment.ipynb" for
        //    older manifests that lack the field)
        let starterName = manifest.starterNotebook ?? "assignment.ipynb"
        do {
            let starterPath = workDir.appendingPathComponent(starterName)
            if fm.fileExists(atPath: starterPath.path),
               submissionFilename != starterName {
                try fm.removeItem(at: starterPath)
            }
        }

        // 4. Extract notebooks to code
        try extractNotebooksToCode(in: workDir)

        // 5. Write student module hint (inline since it's a private method)
        if let submissionFilename, !submissionFilename.isEmpty {
            let ext = URL(fileURLWithPath: submissionFilename).pathExtension.lowercased()
            let hintURL = workDir.appendingPathComponent(".chickadee_student_module")
            if ext == "py" {
                try submissionFilename.write(to: hintURL, atomically: true, encoding: .utf8)
            } else if ext == "ipynb" {
                let pyName = (submissionFilename as NSString).deletingPathExtension + ".py"
                try pyName.write(to: hintURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Decode a TestProperties from JSON string.
    private func makeManifest(_ json: String) throws -> TestProperties {
        try JSONDecoder().decode(TestProperties.self, from: Data(json.utf8))
    }

    // =========================================================================
    // MARK: - Scenario 1: Normal assignment (notebook + solution notebook)
    //   - Starter: assignment.ipynb (in test setup zip)
    //   - Solution: solution.ipynb (validation submission)
    //   - Test scripts: test_public.py
    // =========================================================================

    /// Initial validation: solution.ipynb submitted against setup containing assignment.ipynb.
    /// After setup, only solution.py should exist — no assignment.ipynb or assignment.py.
    func testNormalAssignment_validationWithSolutionNotebook() throws {
        let manifest = try makeManifest("""
        {
            "schemaVersion": 1,
            "testSuites": [{"tier": "public", "script": "test_public.py"}],
            "timeLimitSeconds": 10,
            "starterNotebook": "assignment.ipynb"
        }
        """)

        try simulateRunnerSetup(
            setupFiles: [
                ("assignment.ipynb", minimalNotebook),
                ("test_public.py", "import test_runtime"),
                ("chickadee.py", "# helper")
            ],
            submissionFilename: "solution.ipynb",
            submissionContent: notebook(defining: "solve"),
            manifest: manifest
        )

        // Starter must be removed
        XCTAssertFalse(fileExists("assignment.ipynb"),
                        "Starter notebook must be removed before test execution")
        XCTAssertFalse(fileExists("assignment.py"),
                        "Starter should not be extracted to .py")

        // Solution notebook should be converted to .py
        XCTAssertTrue(fileExists("solution.ipynb"),
                       "Solution notebook file should still be present")
        XCTAssertTrue(fileExists("solution.py"),
                       "Solution notebook must be extracted to solution.py")
        let pyContent = try readFile("solution.py")
        XCTAssertTrue(pyContent.contains("def solve()"),
                       "Extracted .py must contain the solution code")

        // Module hint should point to solution.py
        XCTAssertTrue(fileExists(".chickadee_student_module"))
        let hint = try readFile(".chickadee_student_module")
        XCTAssertEqual(hint, "solution.py")

        // Test scripts and support files still present
        XCTAssertTrue(fileExists("test_public.py"))
        XCTAssertTrue(fileExists("chickadee.py"))
    }

    /// Edit/save re-validation is the same runner flow — verify it still works.
    func testNormalAssignment_editSaveRevalidation() throws {
        // Identical to initial validation — the runner doesn't know the difference.
        let manifest = try makeManifest("""
        {
            "schemaVersion": 1,
            "testSuites": [{"tier": "public", "script": "test_public.py"}],
            "timeLimitSeconds": 10,
            "starterNotebook": "assignment.ipynb"
        }
        """)

        try simulateRunnerSetup(
            setupFiles: [
                ("assignment.ipynb", minimalNotebook),
                ("test_public.py", "import test_runtime")
            ],
            submissionFilename: "solution.ipynb",
            submissionContent: notebook(defining: "my_func"),
            manifest: manifest
        )

        XCTAssertFalse(fileExists("assignment.ipynb"))
        XCTAssertTrue(fileExists("solution.py"))
        let py = try readFile("solution.py")
        XCTAssertTrue(py.contains("def my_func()"))
    }

    // =========================================================================
    // MARK: - Scenario 2: Student submission (named same as starter)
    //   - Student submits assignment.ipynb → overwrites the template
    //   - Starter should NOT be removed (submission IS the starter name)
    // =========================================================================

    func testStudentSubmission_namedSameAsStarter() throws {
        let manifest = try makeManifest("""
        {
            "schemaVersion": 1,
            "testSuites": [{"tier": "public", "script": "test_public.py"}],
            "timeLimitSeconds": 10,
            "starterNotebook": "assignment.ipynb"
        }
        """)

        try simulateRunnerSetup(
            setupFiles: [
                ("assignment.ipynb", minimalNotebook),   // template (will be overwritten)
                ("test_public.py", "import test_runtime")
            ],
            submissionFilename: "assignment.ipynb",        // student overwrites template
            submissionContent: notebook(defining: "student_func"),
            manifest: manifest
        )

        // Starter was overwritten by submission, NOT removed
        XCTAssertTrue(fileExists("assignment.ipynb"),
                       "Student's submission should be present as assignment.ipynb")

        // Should be extracted to .py
        XCTAssertTrue(fileExists("assignment.py"),
                       "Student's notebook must be extracted to assignment.py")
        let py = try readFile("assignment.py")
        XCTAssertTrue(py.contains("def student_func()"),
                       "Extracted .py must contain the student's code, not the template")

        // Module hint should point to assignment.py
        let hint = try readFile(".chickadee_student_module")
        XCTAssertEqual(hint, "assignment.py")
    }

    // =========================================================================
    // MARK: - Scenario 3: Marmoset import with .ipynb canonical solution
    //   - Starter: assignment.ipynb (from starter-files zip)
    //   - Canonical solution: solution.ipynb
    //   - Test scripts: publictest_load.py, chickadee.py, notebook_grade.py
    // =========================================================================

    func testMarmosetImport_ipynbCanonicalSolution_initialValidation() throws {
        let manifest = try makeManifest("""
        {
            "schemaVersion": 1,
            "gradingMode": "worker",
            "testSuites": [
                {"tier": "public", "script": "publictest_load.py"},
                {"tier": "public", "script": "publictest_analysis.py"}
            ],
            "timeLimitSeconds": 10,
            "starterNotebook": "assignment.ipynb"
        }
        """)

        try simulateRunnerSetup(
            setupFiles: [
                ("assignment.ipynb", minimalNotebook),
                ("publictest_load.py", "import notebook_grade"),
                ("publictest_analysis.py", "import notebook_grade"),
                ("notebook_grade.py", "# grading helper"),
                ("chickadee.py", "# test framework")
            ],
            submissionFilename: "solution.ipynb",
            submissionContent: notebook(defining: "load_and_describe"),
            manifest: manifest
        )

        // Starter removed
        XCTAssertFalse(fileExists("assignment.ipynb"),
                        "Starter must be removed so notebook_grade.py sees only one .ipynb")

        // Only one .ipynb should remain: the solution
        let ipynbFiles = try listFiles().filter { $0.hasSuffix(".ipynb") }
        XCTAssertEqual(ipynbFiles.count, 1,
                        "Exactly one .ipynb should remain (the solution), got: \(ipynbFiles)")
        XCTAssertTrue(ipynbFiles.contains("solution.ipynb"))

        // solution.py extracted
        XCTAssertTrue(fileExists("solution.py"))
        let py = try readFile("solution.py")
        XCTAssertTrue(py.contains("def load_and_describe()"))
    }

    func testMarmosetImport_ipynbCanonicalSolution_editSaveRevalidation() throws {
        // Same scenario but represents an edit/save cycle — runner behavior is identical
        let manifest = try makeManifest("""
        {
            "schemaVersion": 1,
            "testSuites": [{"tier": "public", "script": "publictest_load.py"}],
            "timeLimitSeconds": 10,
            "starterNotebook": "assignment.ipynb"
        }
        """)

        try simulateRunnerSetup(
            setupFiles: [
                ("assignment.ipynb", minimalNotebook),
                ("publictest_load.py", "import notebook_grade"),
                ("notebook_grade.py", "# grading helper")
            ],
            submissionFilename: "solution.ipynb",
            submissionContent: notebook(defining: "analyze"),
            manifest: manifest
        )

        XCTAssertFalse(fileExists("assignment.ipynb"))
        XCTAssertEqual(try listFiles().filter { $0.hasSuffix(".ipynb") }.count, 1)
        XCTAssertTrue(fileExists("solution.py"))
    }

    // =========================================================================
    // MARK: - Scenario 4: Marmoset import with .py canonical solution
    //   - Starter: assignment.ipynb
    //   - Canonical: solution.py (Python file, not notebook)
    // =========================================================================

    func testMarmosetImport_pyCanonicalSolution() throws {
        let manifest = try makeManifest("""
        {
            "schemaVersion": 1,
            "testSuites": [{"tier": "public", "script": "publictest_load.py"}],
            "timeLimitSeconds": 10,
            "starterNotebook": "assignment.ipynb"
        }
        """)

        try simulateRunnerSetup(
            setupFiles: [
                ("assignment.ipynb", minimalNotebook),
                ("publictest_load.py", "import test_runtime"),
                ("chickadee.py", "# helper")
            ],
            submissionFilename: "solution.py",
            submissionContent: "def solve():\n    return 42\n",
            manifest: manifest
        )

        // Starter removed
        XCTAssertFalse(fileExists("assignment.ipynb"))

        // No .ipynb files at all
        let ipynbFiles = try listFiles().filter { $0.hasSuffix(".ipynb") }
        XCTAssertTrue(ipynbFiles.isEmpty,
                       "No .ipynb should remain when solution is .py, got: \(ipynbFiles)")

        // solution.py is a raw Python file — should NOT be overwritten by extraction
        XCTAssertTrue(fileExists("solution.py"))
        let py = try readFile("solution.py")
        XCTAssertTrue(py.contains("def solve()"))

        // Module hint
        let hint = try readFile(".chickadee_student_module")
        XCTAssertEqual(hint, "solution.py")
    }

    // =========================================================================
    // MARK: - Scenario 5: Marmoset import with NO starter notebook
    //   - No assignment.ipynb in test setup zip
    //   - Canonical solution: solution.ipynb
    // =========================================================================

    func testMarmosetImport_noStarterNotebook() throws {
        let manifest = try makeManifest("""
        {
            "schemaVersion": 1,
            "testSuites": [{"tier": "public", "script": "publictest_load.py"}],
            "timeLimitSeconds": 10,
            "starterNotebook": "assignment.ipynb"
        }
        """)

        try simulateRunnerSetup(
            setupFiles: [
                // No assignment.ipynb — e.g. Marmoset project had no starter files
                ("publictest_load.py", "import notebook_grade"),
                ("notebook_grade.py", "# grading helper"),
                ("chickadee.py", "# helper")
            ],
            submissionFilename: "solution.ipynb",
            submissionContent: notebook(defining: "process_data"),
            manifest: manifest
        )

        // No assignment.ipynb to remove — should be a no-op
        XCTAssertFalse(fileExists("assignment.ipynb"))

        // Only the solution .ipynb
        let ipynbFiles = try listFiles().filter { $0.hasSuffix(".ipynb") }
        XCTAssertEqual(ipynbFiles, ["solution.ipynb"])

        // solution.py extracted
        XCTAssertTrue(fileExists("solution.py"))
        let py = try readFile("solution.py")
        XCTAssertTrue(py.contains("def process_data()"))
    }

    // =========================================================================
    // MARK: - Scenario 6: No starterNotebook in manifest (legacy test setups)
    //   - Older manifests won't have the field; defaults to nil
    //   - Should not remove any files
    // =========================================================================

    func testLegacyManifest_noStarterNotebookField() throws {
        let manifest = try makeManifest("""
        {
            "schemaVersion": 1,
            "testSuites": [{"tier": "public", "script": "test_public.sh"}],
            "timeLimitSeconds": 10
        }
        """)

        XCTAssertNil(manifest.starterNotebook,
                      "Legacy manifests should have nil starterNotebook")

        try simulateRunnerSetup(
            setupFiles: [
                ("test_public.sh", "#!/bin/sh\nexit 0"),
                ("helper.py", "# support file")
            ],
            submissionFilename: "submission.py",
            submissionContent: "def main(): pass\n",
            manifest: manifest
        )

        // Everything should remain untouched
        XCTAssertTrue(fileExists("test_public.sh"))
        XCTAssertTrue(fileExists("helper.py"))
        XCTAssertTrue(fileExists("submission.py"))

        let hint = try readFile(".chickadee_student_module")
        XCTAssertEqual(hint, "submission.py")
    }

    // =========================================================================
    // MARK: - Scenario 6b: Legacy manifest with notebook assignment
    //   - starterNotebook is nil (old manifest), but assignment.ipynb is in zip
    //   - Must still remove assignment.ipynb (default fallback)
    // =========================================================================

    func testLegacyManifest_notebookAssignment_starterStillRemoved() throws {
        let manifest = try makeManifest("""
        {
            "schemaVersion": 1,
            "testSuites": [{"tier": "public", "script": "test_public.py"}],
            "timeLimitSeconds": 10
        }
        """)

        XCTAssertNil(manifest.starterNotebook)

        try simulateRunnerSetup(
            setupFiles: [
                ("assignment.ipynb", minimalNotebook),
                ("test_public.py", "import test_runtime")
            ],
            submissionFilename: "solution.ipynb",
            submissionContent: notebook(defining: "solve"),
            manifest: manifest
        )

        // Even without starterNotebook in manifest, assignment.ipynb is removed
        XCTAssertFalse(fileExists("assignment.ipynb"),
                        "Legacy manifests must still remove assignment.ipynb by default")
        XCTAssertFalse(fileExists("assignment.py"),
                        "Starter should not be extracted to .py")

        // Solution extracted correctly
        XCTAssertTrue(fileExists("solution.py"))
        let py = try readFile("solution.py")
        XCTAssertTrue(py.contains("def solve()"))
    }

    /// Legacy manifest, student submits assignment.ipynb — should NOT be removed.
    func testLegacyManifest_studentSubmitsAssignment_notRemoved() throws {
        let manifest = try makeManifest("""
        {
            "schemaVersion": 1,
            "testSuites": [{"tier": "public", "script": "test_public.py"}],
            "timeLimitSeconds": 10
        }
        """)

        try simulateRunnerSetup(
            setupFiles: [
                ("assignment.ipynb", minimalNotebook),
                ("test_public.py", "import test_runtime")
            ],
            submissionFilename: "assignment.ipynb",
            submissionContent: notebook(defining: "student_work"),
            manifest: manifest
        )

        XCTAssertTrue(fileExists("assignment.ipynb"))
        XCTAssertTrue(fileExists("assignment.py"))
        let py = try readFile("assignment.py")
        XCTAssertTrue(py.contains("def student_work()"))
    }

    // =========================================================================
    // MARK: - Scenario 7: Shell-script assignment (no notebooks at all)
    //   - Pure shell-script test suite, no .ipynb files anywhere
    // =========================================================================

    func testShellScriptAssignment_noNotebooks() throws {
        let manifest = try makeManifest("""
        {
            "schemaVersion": 1,
            "testSuites": [
                {"tier": "public", "script": "test_01.sh"},
                {"tier": "release", "script": "test_02.sh"}
            ],
            "timeLimitSeconds": 10
        }
        """)

        try simulateRunnerSetup(
            setupFiles: [
                ("test_01.sh", "#!/bin/sh\nexit 0"),
                ("test_02.sh", "#!/bin/sh\nexit 0")
            ],
            submissionFilename: nil,
            submissionContent: "",  // zip submission; files already in workDir
            manifest: manifest
        )

        XCTAssertTrue(fileExists("test_01.sh"))
        XCTAssertTrue(fileExists("test_02.sh"))
        let ipynbFiles = try listFiles().filter { $0.hasSuffix(".ipynb") }
        XCTAssertTrue(ipynbFiles.isEmpty, "No notebooks should exist")
    }

    // =========================================================================
    // MARK: - Duplicate prevention tests
    //   - The whole reason this code exists: grading scripts must not see
    //     multiple .ipynb files or duplicate .py function definitions.
    // =========================================================================

    /// If the starter were NOT removed, notebook_grade.py would find two .ipynb files.
    func testNoDuplicateNotebooks_afterSetup() throws {
        let manifest = try makeManifest("""
        {
            "schemaVersion": 1,
            "testSuites": [{"tier": "public", "script": "test.py"}],
            "timeLimitSeconds": 10,
            "starterNotebook": "assignment.ipynb"
        }
        """)

        // Both the starter and the solution define the same function
        let starterNB = notebook(defining: "compute")
        let solutionNB = notebook(defining: "compute")

        try simulateRunnerSetup(
            setupFiles: [
                ("assignment.ipynb", starterNB),
                ("test.py", "# test script")
            ],
            submissionFilename: "solution.ipynb",
            submissionContent: solutionNB,
            manifest: manifest
        )

        // Only one .ipynb, only one .py with "def compute"
        let ipynbFiles = try listFiles().filter { $0.hasSuffix(".ipynb") }
        XCTAssertEqual(ipynbFiles.count, 1, "Only solution.ipynb should remain")

        let pyFiles = try listFiles().filter {
            $0.hasSuffix(".py") && !$0.hasPrefix("test") && $0 != "chickadee.py"
                && $0 != "notebook_grade.py"
        }
        XCTAssertEqual(pyFiles.count, 1,
                        "Only one extracted .py file (solution.py) should exist, got: \(pyFiles)")
    }

    /// Verify no .py collision when solution is .py and setup has .ipynb starter.
    func testNoDuplicatePy_whenSolutionIsPyAndStarterIsNotebook() throws {
        let manifest = try makeManifest("""
        {
            "schemaVersion": 1,
            "testSuites": [{"tier": "public", "script": "test.py"}],
            "timeLimitSeconds": 10,
            "starterNotebook": "assignment.ipynb"
        }
        """)

        try simulateRunnerSetup(
            setupFiles: [
                ("assignment.ipynb", notebook(defining: "solve")),
                ("test.py", "# test")
            ],
            submissionFilename: "solution.py",
            submissionContent: "def solve():\n    return 1\n",
            manifest: manifest
        )

        // assignment.ipynb removed, no assignment.py generated
        XCTAssertFalse(fileExists("assignment.ipynb"))
        XCTAssertFalse(fileExists("assignment.py"))

        // Only solution.py
        XCTAssertTrue(fileExists("solution.py"))
        let py = try readFile("solution.py")
        XCTAssertTrue(py.contains("def solve()"))
    }

    // =========================================================================
    // MARK: - extractNotebooksToCode skip-list tests
    //   - Verify that solution.ipynb IS extracted (it should be — it's the
    //     submission for validation runs)
    //   - Verify that assignment.ipynb is NOT extracted when present alongside
    //     the student's differently-named notebook
    // =========================================================================

    func testExtractNotebooksToCode_extractsSolutionNotebook() throws {
        // solution.ipynb should be extracted to solution.py
        try writeFile(notebook(defining: "my_solution"), name: "solution.ipynb")

        try extractNotebooksToCode(in: workDir)

        XCTAssertTrue(fileExists("solution.py"),
                       "solution.ipynb must be extracted to solution.py")
        let py = try readFile("solution.py")
        XCTAssertTrue(py.contains("def my_solution()"))
    }

    func testExtractNotebooksToCode_extractsAssignmentNotebook() throws {
        // assignment.ipynb should also be extracted (if still present after
        // starter removal, e.g. when the student submitted assignment.ipynb)
        try writeFile(notebook(defining: "student_work"), name: "assignment.ipynb")

        try extractNotebooksToCode(in: workDir)

        XCTAssertTrue(fileExists("assignment.py"),
                       "assignment.ipynb must be extracted to assignment.py")
        let py = try readFile("assignment.py")
        XCTAssertTrue(py.contains("def student_work()"))
    }

    func testExtractNotebooksToCode_extractsArbitrarilyNamedNotebook() throws {
        try writeFile(notebook(defining: "lab_work"), name: "Lab3_Analysis.ipynb")

        try extractNotebooksToCode(in: workDir)

        XCTAssertTrue(fileExists("Lab3_Analysis.py"),
                       "Arbitrarily-named notebook must be extracted")
        let py = try readFile("Lab3_Analysis.py")
        XCTAssertTrue(py.contains("def lab_work()"))
    }

    // =========================================================================
    // MARK: - starterNotebook manifest field tests
    // =========================================================================

    func testManifestWithStarterNotebook_decodesCorrectly() throws {
        let m = try makeManifest("""
        {
            "schemaVersion": 1,
            "testSuites": [],
            "timeLimitSeconds": 10,
            "starterNotebook": "my_starter.ipynb"
        }
        """)
        XCTAssertEqual(m.starterNotebook, "my_starter.ipynb")
    }

    func testManifestWithoutStarterNotebook_defaultsToNil() throws {
        let m = try makeManifest("""
        {
            "schemaVersion": 1,
            "testSuites": [],
            "timeLimitSeconds": 10
        }
        """)
        XCTAssertNil(m.starterNotebook)
    }

    // =========================================================================
    // MARK: - Custom starter notebook name
    //   - Verify the manifest-driven removal works with non-default names
    // =========================================================================

    func testCustomStarterName_removedBeforeTests() throws {
        let manifest = try makeManifest("""
        {
            "schemaVersion": 1,
            "testSuites": [{"tier": "public", "script": "test.py"}],
            "timeLimitSeconds": 10,
            "starterNotebook": "Lab3_Starter.ipynb"
        }
        """)

        try simulateRunnerSetup(
            setupFiles: [
                ("Lab3_Starter.ipynb", minimalNotebook),
                ("test.py", "# test")
            ],
            submissionFilename: "solution.ipynb",
            submissionContent: notebook(defining: "analyze"),
            manifest: manifest
        )

        XCTAssertFalse(fileExists("Lab3_Starter.ipynb"),
                        "Custom starter must be removed")
        XCTAssertFalse(fileExists("Lab3_Starter.py"),
                        "Custom starter must not be extracted to .py")
        XCTAssertTrue(fileExists("solution.py"))
    }

    /// Student submission named same as custom starter — should NOT be removed.
    func testCustomStarterName_studentSubmitsSameName() throws {
        let manifest = try makeManifest("""
        {
            "schemaVersion": 1,
            "testSuites": [{"tier": "public", "script": "test.py"}],
            "timeLimitSeconds": 10,
            "starterNotebook": "Lab3_Starter.ipynb"
        }
        """)

        try simulateRunnerSetup(
            setupFiles: [
                ("Lab3_Starter.ipynb", minimalNotebook),
                ("test.py", "# test")
            ],
            submissionFilename: "Lab3_Starter.ipynb",
            submissionContent: notebook(defining: "student_analysis"),
            manifest: manifest
        )

        // Student's file overwrote the template; should NOT be deleted
        XCTAssertTrue(fileExists("Lab3_Starter.ipynb"))
        XCTAssertTrue(fileExists("Lab3_Starter.py"))
        let py = try readFile("Lab3_Starter.py")
        XCTAssertTrue(py.contains("def student_analysis()"),
                       "Extracted .py must have the student's code, not the template")
    }

    // =========================================================================
    // MARK: - Support files are preserved
    //   - Test scripts, helper libraries, data files must survive setup
    // =========================================================================

    func testSupportFilesPreserved() throws {
        let manifest = try makeManifest("""
        {
            "schemaVersion": 1,
            "testSuites": [{"tier": "public", "script": "publictest_load.py"}],
            "timeLimitSeconds": 10,
            "starterNotebook": "assignment.ipynb"
        }
        """)

        try simulateRunnerSetup(
            setupFiles: [
                ("assignment.ipynb", minimalNotebook),
                ("publictest_load.py", "import notebook_grade"),
                ("notebook_grade.py", "# grading helper"),
                ("chickadee.py", "# framework"),
                ("mini_data_lib.py", "# data library"),
                ("test_data.csv", "a,b,c\n1,2,3")
            ],
            submissionFilename: "solution.ipynb",
            submissionContent: notebook(defining: "solve"),
            manifest: manifest
        )

        // All support files must survive
        XCTAssertTrue(fileExists("publictest_load.py"))
        XCTAssertTrue(fileExists("notebook_grade.py"))
        XCTAssertTrue(fileExists("chickadee.py"))
        XCTAssertTrue(fileExists("mini_data_lib.py"))
        XCTAssertTrue(fileExists("test_data.csv"))

        // Support .py files must NOT be overwritten by extraction
        let chickadee = try readFile("chickadee.py")
        XCTAssertEqual(chickadee, "# framework",
                        "Support .py files must not be modified by notebook extraction")
    }
}
