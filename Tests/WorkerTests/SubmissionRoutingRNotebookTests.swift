import Core
import Foundation
import Testing

@testable import chickadee_runner

// MARK: - Submission routing: R-kernel notebooks
//
// Regression coverage for the submission-router gap where ANY `.ipynb`
// submission was Python-normalized, so a worker-graded R *notebook* assignment
// never produced `solution.R` (the tests then errored with "No R submission
// file was found to grade"). An R-kernel notebook must skip the Python
// normalizer and be extracted to `.R` by `extractNotebooksToCode`.

@Suite(.timeLimit(.minutes(1))) final class SubmissionRoutingRNotebookTests {
    private let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: tmpDir) }

    private static let rNotebook = #"""
        {"cells":[{"cell_type":"code","metadata":{},"source":["x <- 1\n"]}],"metadata":{"kernelspec":{"name":"xr","display_name":"R (xeus-r)","language":"R"},"language_info":{"name":"r"}},"nbformat":4,"nbformat_minor":5}
        """#

    private static let irNotebook = #"""
        {"cells":[{"cell_type":"code","metadata":{},"source":["x <- 1\n"]}],"metadata":{"kernelspec":{"name":"ir","display_name":"R","language":"R"}},"nbformat":4,"nbformat_minor":5}
        """#

    private static let pythonNotebook = #"""
        {"cells":[{"cell_type":"code","metadata":{},"source":["x = 1\n"]}],"metadata":{"kernelspec":{"name":"python","display_name":"Python (Pyodide)","language":"python"},"language_info":{"name":"python"}},"nbformat":4,"nbformat_minor":5}
        """#

    private func stage(_ json: String, as name: String = "solution.ipynb") throws {
        try json.write(to: tmpDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func manifest(_ json: String) throws -> TestProperties {
        try JSONDecoder().decode(TestProperties.self, from: Data(json.utf8))
    }

    private let rOnlyManifest =
        #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_x.R"}],"timeLimitSeconds":10}"#
    private let pyOnlyManifest =
        #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_x.py"}],"timeLimitSeconds":10}"#
    private let mixedManifest =
        #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_x.R"},{"tier":"public","script":"publictest_y.py"}],"timeLimitSeconds":10}"#
    private let rWithRequiredPyManifest =
        #"{"schemaVersion":1,"requiredFiles":["helper.py"],"testSuites":[{"tier":"public","script":"publictest_x.R"}],"timeLimitSeconds":10}"#
    private let shellOnlyManifest =
        #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_x.sh"}],"timeLimitSeconds":10}"#

    @Test func detectsXeusRKernelNotebook() throws {
        try stage(Self.rNotebook)
        #expect(submissionIsRNotebook(submissionDirectory: tmpDir, submissionFilename: "solution.ipynb"))
    }

    @Test func detectsIRKernelNotebook() throws {
        try stage(Self.irNotebook)
        #expect(submissionIsRNotebook(submissionDirectory: tmpDir, submissionFilename: "solution.ipynb"))
    }

    @Test func pythonNotebookNotDetectedAsR() throws {
        try stage(Self.pythonNotebook)
        #expect(!submissionIsRNotebook(submissionDirectory: tmpDir, submissionFilename: "solution.ipynb"))
    }

    @Test func rNotebookSkipsPythonNormalization() throws {
        try stage(Self.rNotebook)
        #expect(
            !shouldNormalizePythonSubmission(
                manifest: try manifest(rOnlyManifest), submissionFilename: "solution.ipynb",
                submissionDirectory: tmpDir))
    }

    @Test func pythonNotebookStillNormalizes() throws {
        try stage(Self.pythonNotebook)
        #expect(
            shouldNormalizePythonSubmission(
                manifest: try manifest(pyOnlyManifest), submissionFilename: "solution.ipynb",
                submissionDirectory: tmpDir))
    }

    @Test func rNotebookWithPythonSuiteStaysPython() throws {
        // Mixed setup: a `.py` test script means the Python normalizer still runs
        // (those tests need `solution.py` + the auto-loaded student_module).
        try stage(Self.rNotebook)
        #expect(
            shouldNormalizePythonSubmission(
                manifest: try manifest(pyOnlyManifest), submissionFilename: "solution.ipynb",
                submissionDirectory: tmpDir))
    }

    @Test func rNotebookRoutesToExtractionProducingDotR() throws {
        // End-to-end of the branch the router now selects: the R notebook is
        // extracted to `solution.R` (not `solution.py`) by extractNotebooksToCode.
        try stage(Self.rNotebook)
        #expect(
            !shouldNormalizePythonSubmission(
                manifest: try manifest(rOnlyManifest), submissionFilename: "solution.ipynb",
                submissionDirectory: tmpDir))
        try extractNotebooksToCode(in: tmpDir)
        #expect(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("solution.R").path))
        #expect(
            !FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("solution.py").path))
    }

    // MARK: - Manifest-authoritative language (recovers editor-mangled kernelspecs)

    @Test func manifestTargetsRForPureRSuite() throws {
        #expect(manifestTargetsRSubmission(try manifest(rOnlyManifest)))
    }

    @Test func manifestDoesNotTargetRForPythonSuite() throws {
        #expect(!manifestTargetsRSubmission(try manifest(pyOnlyManifest)))
    }

    @Test func manifestDoesNotTargetRForMixedSuite() throws {
        // A `.py` test script means Python is in play; not a pure-R suite.
        #expect(!manifestTargetsRSubmission(try manifest(mixedManifest)))
    }

    @Test func manifestDoesNotTargetRWhenRequiredPythonFilePresent() throws {
        #expect(!manifestTargetsRSubmission(try manifest(rWithRequiredPyManifest)))
    }

    @Test func manifestDoesNotTargetRForShellOnlySuite() throws {
        // No `.R` script at all — leave the existing (kernelspec) detection alone.
        #expect(!manifestTargetsRSubmission(try manifest(shellOnlyManifest)))
    }

    @Test func pythonKernelNotebookOnPureRSuiteSkipsPythonNormalization() throws {
        // THE regression: an in-browser editor saved an R notebook under the
        // Pyodide/Python kernel. On a pure-R assignment the manifest is
        // authoritative, so the router must NOT Python-normalize it — otherwise
        // the tests error with "No R submission file was found to grade". This is
        // also what recovers a submission stored before the submit-time fix.
        try stage(Self.pythonNotebook)
        #expect(
            !shouldNormalizePythonSubmission(
                manifest: try manifest(rOnlyManifest), submissionFilename: "solution.ipynb",
                submissionDirectory: tmpDir))
    }

    @Test func forcedRExtractionProducesDotRFromPythonKernelNotebook() throws {
        // The recovery mechanism end-to-end: a Python-kernel notebook, forced to
        // R by the pure-R manifest, is extracted to `solution.R` (not `.py`).
        try stage(Self.pythonNotebook)
        try extractNotebooksToCode(in: tmpDir, forcedLanguage: .r)
        #expect(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("solution.R").path))
        #expect(
            !FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("solution.py").path))
    }

    @Test func forcedRExtractionCopiesCellSourceVerbatim() throws {
        // R extraction must not run the Python cell-sanitizer: the R source is
        // copied through unchanged so `source()` sees the student's code.
        try stage(Self.pythonNotebook)
        try extractNotebooksToCode(in: tmpDir, forcedLanguage: .r)
        let produced = try String(
            contentsOf: tmpDir.appendingPathComponent("solution.R"), encoding: .utf8)
        #expect(produced.contains("x = 1"))
    }
}
