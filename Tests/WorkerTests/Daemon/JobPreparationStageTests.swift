// Tests/WorkerTests/Daemon/JobPreparationStageTests.swift
//
// The prepare-phase stages of `RunnerDaemon+JobPreparation.swift` that need
// no server: the archive arm of the submission staging (and the extraction
// limit it applies), the starter-notebook cleanup, and the `.extractToSource`
// arm of `normalizeSubmission` (the merge that refuses protected files, and
// the student-module hint in the routed language).

import ChickadeeTestSupport
import Foundation
import Testing

@testable import Core
@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) final class JobPreparationStageTests {

    let root: URL
    let paths: JobWorkspacePaths
    let setupDir: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-job-prep-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        setupDir = root.appendingPathComponent("setup", isDirectory: true)
        paths = JobWorkspacePaths(
            tempRoot: root, workDir: work,
            submissionZip: work.appendingPathComponent("submission.zip"),
            submissionDir: work.appendingPathComponent("submission", isDirectory: true))
        for directory in [work, setupDir, paths.submissionDir] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private static func daemon() -> WorkerDaemon {
        WorkerDaemon(
            poller: NoJobPoller(),
            reporter: NoopReporter(),
            runner: UnsandboxedScriptRunner(),
            apiBaseURL: testURL("http://127.0.0.1:9"),
            workerID: "job-preparation-stage-tests",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            config: .defaults)
    }

    private static func job(
        manifest: TestProperties, submissionFilename: String?, language: AssignmentLanguage?
    ) -> Job {
        Job(
            submissionID: "sub_prep", testSetupID: "setup_prep", attemptNumber: 1,
            submissionURL: testURL("https://x.test/s.zip"),
            testSetupURL: testURL("https://x.test/t.zip"),
            manifest: manifest, submissionFilename: submissionFilename,
            language: language)
    }

    private static func notebook(code: String) -> String {
        """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","metadata":{},"source":[\(code.debugDescription)]}]}
        """
    }

    private func write(_ contents: String, to directory: URL, as name: String) throws {
        try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func exists(_ directory: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    /// Zips the contents of `source` to `paths.submissionZip`.
    private func zipSubmission(from source: URL) async throws {
        try await createZipArchive(sourceDir: source, outputPath: paths.submissionZip.path)
    }

    // MARK: - Archive submissions

    /// A zip upload carries no filename, so it is extracted into the
    /// submission directory and timed as the unpack stage.
    @Test func anArchiveSubmissionIsExtractedIntoTheSubmissionDirectory() async throws {
        let source = root.appendingPathComponent("zip-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try write("x = 1\n", to: source, as: "solution.py")
        try write("notes\n", to: source, as: "README.txt")
        try await zipSubmission(from: source)

        var timings = JobStageTimings()
        let job = Self.job(manifest: TestProperties(language: nil), submissionFilename: nil, language: nil)
        try await Self.daemon().stageSubmissionIntoWorkspace(job: job, paths: paths, stageTimings: &timings)

        #expect(exists(paths.submissionDir, "solution.py"))
        #expect(exists(paths.submissionDir, "README.txt"))
        #expect(timings.value(for: "submission_unpack") != nil)
    }

    /// A student built the archive, and it unpacks outside the sandbox's disk
    /// limit, so the submission extraction limit applies (#2898). One entry
    /// over the limit's count is refused before anything is written.
    @Test func anArchiveOverTheSubmissionEntryLimitIsRefused() async throws {
        let source = root.appendingPathComponent("zip-many", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for index in 0...ZipExtractionLimits.submission.maxEntryCount {
            try Data().write(to: source.appendingPathComponent("f\(index)"))
        }
        try await zipSubmission(from: source)

        var timings = JobStageTimings()
        let job = Self.job(manifest: TestProperties(language: nil), submissionFilename: nil, language: nil)
        await #expect(throws: ZipArchiverError.self) {
            try await Self.daemon().stageSubmissionIntoWorkspace(job: job, paths: self.paths, stageTimings: &timings)
        }
        #expect(!exists(paths.submissionDir, "f0"))
    }

    // MARK: - Starter notebook cleanup

    /// An older manifest names no starter notebook; the conventional name is
    /// removed, so a script scanning for `*.ipynb` sees only the submission.
    @Test func theConventionalStarterIsRemovedWhenTheManifestNamesNone() async throws {
        try write("{}", to: setupDir, as: "assignment.ipynb")

        var timings = JobStageTimings()
        try await Self.daemon().removeStarterNotebookIfPresent(
            manifest: RunnerManifest(TestProperties(language: nil)), testSetupDir: setupDir,
            submissionFilename: "work.ipynb", stageTimings: &timings)

        #expect(!exists(setupDir, "assignment.ipynb"))
        #expect(timings.value(for: "starter_cleanup") != nil)
    }

    @Test func aNamedStarterIsRemovedAndTheConventionalNameIsKept() async throws {
        try write("{}", to: setupDir, as: "lab3.ipynb")
        try write("{}", to: setupDir, as: "assignment.ipynb")

        var timings = JobStageTimings()
        try await Self.daemon().removeStarterNotebookIfPresent(
            manifest: RunnerManifest(TestProperties(starterNotebook: "lab3.ipynb", language: nil)),
            testSetupDir: setupDir, submissionFilename: "work.ipynb", stageTimings: &timings)

        #expect(!exists(setupDir, "lab3.ipynb"))
        #expect(exists(setupDir, "assignment.ipynb"))
    }

    /// The submission was uploaded under the starter's own name, so the file
    /// in the workspace is not a template to remove.
    @Test func aStarterWithTheSubmissionsNameIsKept() async throws {
        try write("{}", to: setupDir, as: "assignment.ipynb")

        var timings = JobStageTimings()
        try await Self.daemon().removeStarterNotebookIfPresent(
            manifest: RunnerManifest(TestProperties(language: nil)), testSetupDir: setupDir,
            submissionFilename: "assignment.ipynb", stageTimings: &timings)

        #expect(exists(setupDir, "assignment.ipynb"))
    }

    // MARK: - Extract to source

    /// An R-owned suite: the notebook is extracted to R whatever it declares,
    /// a submitted file with a test script's name is not merged and is warned
    /// about, and the hint names the R file.
    @Test func anOwnedLanguageExtractsToItsSourceAndRefusesProtectedFiles() async throws {
        let manifest = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "test_a.R")], language: .r)
        try write("instructor <- TRUE\n", to: setupDir, as: "test_a.R")
        try write(Self.notebook(code: "x <- 1\n"), to: paths.submissionDir, as: "analysis.ipynb")
        try write("student <- TRUE\n", to: paths.submissionDir, as: "test_a.R")

        var timings = JobStageTimings()
        let job = Self.job(manifest: manifest, submissionFilename: "analysis.ipynb", language: .r)
        let (warnings, module) = try await Self.daemon().normalizeSubmission(
            job: job, manifest: RunnerManifest(manifest), paths: paths, testSetupDir: setupDir,
            stageTimings: &timings)

        #expect(module == "analysis.R")
        #expect(exists(setupDir, "analysis.R"))
        #expect(!exists(setupDir, "analysis.py"))
        let instructorScript = try String(
            contentsOf: setupDir.appendingPathComponent("test_a.R"), encoding: .utf8)
        #expect(instructorScript == "instructor <- TRUE\n")
        #expect(warnings.contains(protectedFileSkippedWarning("test_a.R")))
        #expect(timings.value(for: "submission_prepare") != nil)
    }

    /// An archive upload names no file, so the hint comes from what the
    /// submission held, not from the merged workspace where an instructor's
    /// helper sorts first (#1390).
    @Test func anArchiveHintNamesTheSubmittedFileNotTheInstructorsHelper() async throws {
        let manifest = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "test_a.R")], language: .r)
        try write("helper <- 1\n", to: setupDir, as: "aaa_helpers.R")
        try write("solve <- 1\n", to: paths.submissionDir, as: "solution.R")

        var timings = JobStageTimings()
        let job = Self.job(manifest: manifest, submissionFilename: nil, language: .r)
        let (warnings, module) = try await Self.daemon().normalizeSubmission(
            job: job, manifest: RunnerManifest(manifest), paths: paths, testSetupDir: setupDir,
            stageTimings: &timings)

        #expect(module == "solution.R")
        #expect(warnings.isEmpty)
        #expect(exists(setupDir, "solution.R"))
    }

    /// Nothing claimed the submission, so the extractor trusted the notebook
    /// and the hint is read as Python. A Lua file the student sent is not a
    /// Python module, so no hint is named.
    @Test func anUnclaimedSubmissionReadsTheHintAsPython() async throws {
        let manifest = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "test.sh")], language: nil)
        try write("print(1)\n", to: paths.submissionDir, as: "main.lua")

        var timings = JobStageTimings()
        let job = Self.job(manifest: manifest, submissionFilename: nil, language: nil)
        let (_, module) = try await Self.daemon().normalizeSubmission(
            job: job, manifest: RunnerManifest(manifest), paths: paths, testSetupDir: setupDir,
            stageTimings: &timings)

        #expect(module == nil)
        #expect(exists(setupDir, "main.lua"))
    }
}
