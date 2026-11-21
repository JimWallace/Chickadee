// Tests/WorkerTests/Daemon/JobPreparationDownloadTests.swift
//
// The prepare-phase paths of `RunnerDaemon+JobPreparation.swift` that fetch
// from the server, against a local `python3 http.server`: a submission
// opponent (single and matrix) is downloaded before it is staged, and a
// successful `make` step is timed as its own stage.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(3))) final class JobPreparationDownloadTests {

    let root: URL
    let served: URL
    let paths: JobWorkspacePaths
    let setupDir: URL
    let cacheRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-job-prep-dl-\(UUID().uuidString)", isDirectory: true)
        served = root.appendingPathComponent("served", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        setupDir = root.appendingPathComponent("setup", isDirectory: true)
        cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        paths = JobWorkspacePaths(
            tempRoot: root, workDir: work,
            submissionZip: work.appendingPathComponent("submission.bin"),
            submissionDir: work.appendingPathComponent("submission", isDirectory: true))
        for directory in [served, work, setupDir, cacheRoot, paths.submissionDir] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func daemon() -> WorkerDaemon {
        WorkerDaemon(
            poller: NoJobPoller(),
            reporter: NoopReporter(),
            runner: UnsandboxedScriptRunner(),
            apiBaseURL: testURL("http://127.0.0.1:9"),
            workerID: "job-preparation-download-tests",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            downloadRetryPolicy: RunnerRetryPolicy(enabled: true, maxAttempts: 2, baseDelayMs: 10, maxDelayMs: 20),
            testSetupCache: TestSetupCache(cacheRoot: cacheRoot),
            config: .defaults)
    }

    private static func job(
        manifest: TestProperties = TestProperties(language: nil),
        submissionURL: URL = testURL("https://x.test/s.zip"),
        testSetupURL: URL = testURL("https://x.test/t.zip"),
        submissionFilename: String? = "strategy.py",
        opponent: JobOpponent? = nil,
        opponents: [JobOpponent]? = nil
    ) -> Job {
        Job(
            submissionID: "sub_prep_dl", testSetupID: "setup_prep_dl_\(UUID().uuidString)", attemptNumber: 1,
            submissionURL: submissionURL, testSetupURL: testSetupURL,
            manifest: manifest, submissionFilename: submissionFilename,
            language: nil, opponent: opponent, opponents: opponents)
    }

    private static func submissionOpponent(id: String, url: URL) -> JobOpponent {
        JobOpponent(
            supportFile: nil,
            matchSeed: JobOpponent.matchSeed(submissionID: "sub_prep_dl", opponentIdentity: id),
            submissionID: id, submissionURL: url, submissionFilename: "\(id).py")
    }

    private func serve(_ contents: String, as name: String) throws {
        try contents.write(to: served.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Opponent downloads

    /// A champion's submission is downloaded first, then staged under its
    /// submitted name with the module hint beside it.
    @Test func aSingleSubmissionOpponentIsDownloadedThenStaged() async throws {
        let server = try await LocalHTTPTestServer.staticFiles(directory: served)
        defer { server.stop() }
        try serve("move = 'rock'\n", as: "champ.py")
        let opponent = Self.submissionOpponent(
            id: "champ", url: testURL("http://127.0.0.1:\(server.port)/champ.py"))

        let staged = try await daemon().stageOpponents(
            job: Self.job(opponent: opponent), paths: paths, testSetupDir: setupDir)

        let directory = try #require(staged.single)
        #expect(directory == opponentDirectory(workDir: paths.workDir))
        #expect(staged.matrix.isEmpty)
        #expect(try contents(of: directory.appendingPathComponent("champ.py")) == "move = 'rock'\n")
        #expect(try contents(of: directory.appendingPathComponent(".chickadee_student_module")) == "champ.py")
        #expect(FileManager.default.fileExists(atPath: opponentDownloadDestination(workDir: paths.workDir).path))
    }

    /// A download that fails is the job's error: the opponent is never
    /// staged, so no match runs with nobody on the other side.
    @Test func aFailedOpponentDownloadFailsTheJob() async throws {
        let server = try await LocalHTTPTestServer.alwaysNotFound()
        defer { server.stop() }
        let opponent = Self.submissionOpponent(
            id: "champ", url: testURL("http://127.0.0.1:\(server.port)/champ.py"))

        await #expect(throws: WorkerDaemonError.self) {
            _ = try await self.daemon().stageOpponents(
                job: Self.job(opponent: opponent), paths: self.paths, testSetupDir: self.setupDir)
        }
        #expect(!FileManager.default.fileExists(atPath: opponentDirectory(workDir: paths.workDir).path))
    }

    /// Each classmate of a matrix job is downloaded to its own indexed file,
    /// so two downloads never collide, and staged in `opponent-<index>/`.
    @Test func eachMatrixSubmissionOpponentIsDownloadedToItsOwnFile() async throws {
        let server = try await LocalHTTPTestServer.staticFiles(directory: served)
        defer { server.stop() }
        let ids = ["alice", "bob", "carol"]
        for id in ids { try serve("name = '\(id)'\n", as: "\(id).py") }
        let opponents = ids.map {
            Self.submissionOpponent(id: $0, url: testURL("http://127.0.0.1:\(server.port)/\($0).py"))
        }

        let staged = try await daemon().stageOpponents(
            job: Self.job(opponents: opponents), paths: paths, testSetupDir: setupDir)

        #expect(staged.single == nil)
        #expect(staged.matrix == ids.indices.map { opponentDirectory(workDir: paths.workDir, index: $0) })
        for (index, id) in ids.enumerated() {
            let download = opponentDownloadDestination(workDir: paths.workDir, index: index)
            #expect(try contents(of: download) == "name = '\(id)'\n")
            #expect(try contents(of: staged.matrix[index].appendingPathComponent("\(id).py")) == "name = '\(id)'\n")
        }
    }

    // MARK: - Make step

    /// A make step that succeeds runs in the prepared workspace and records
    /// its own stage timing.
    @Test(.requiresMake) func aSuccessfulMakeStepIsTimed() async throws {
        let server = try await LocalHTTPTestServer.staticFiles(directory: served)
        defer { server.stop() }
        let setupSource = root.appendingPathComponent("setup-source", isDirectory: true)
        try FileManager.default.createDirectory(at: setupSource, withIntermediateDirectories: true)
        try "#!/bin/sh\necho passed\n".write(
            to: setupSource.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
        try "all:\n\ttouch built.txt\n".write(
            to: setupSource.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        try await createZipArchive(
            sourceDir: setupSource, outputPath: served.appendingPathComponent("setup.zip").path)
        try serve("x = 1\n", as: "solution.py")

        let manifest = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "test.sh")],
            makefile: MakefileConfig(target: nil), language: nil)
        let job = Self.job(
            manifest: manifest,
            submissionURL: testURL("http://127.0.0.1:\(server.port)/solution.py"),
            testSetupURL: testURL("http://127.0.0.1:\(server.port)/setup.zip"),
            submissionFilename: "solution.py")

        var timings = JobStageTimings()
        let prepared = try await daemon().prepareJobWorkspace(job: job, paths: paths, stageTimings: &timings)
        defer { try? FileManager.default.removeItem(at: prepared.testSetupDir) }

        #expect(FileManager.default.fileExists(atPath: prepared.testSetupDir.appendingPathComponent("built.txt").path))
        #expect(timings.value(for: "make_step") != nil)
    }
}
