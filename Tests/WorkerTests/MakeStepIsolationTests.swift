// Tests/WorkerTests/MakeStepIsolationTests.swift
//
// #2250: the pre-test `make` step ran outside the sandbox even with
// `--sandbox`, and the submission, merged into the workspace before `make`
// runs, could supply the makefile. GNU make reads `GNUmakefile` before
// `Makefile`, so on any assignment with a make step a student could choose
// commands that then ran with the network and every other job's directory.
// These tests prove both halves are closed: the makefile names are protected
// from the merge when the manifest has a make step, and `make` under the
// sandboxed runner cannot see a sibling job's directory but still leaves its
// build output in the job's own directory.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite struct MakefileProtectionTests {

    private static func manifest(makefile: MakefileConfig?) -> TestProperties {
        TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "test_build.sh")],
            makefile: makefile,
            language: .cpp)
    }

    @Test func withAMakeStepEveryMakefileNameIsProtected() {
        let names = protectedWorkspaceFilenames(manifest: Self.manifest(makefile: MakefileConfig(target: nil)))
        #expect(names.isSuperset(of: ["GNUmakefile", "makefile", "Makefile"]))
    }

    /// Without a make step a makefile is ordinary submission content, which a
    /// hand-written test script may run inside the sandbox.
    @Test func withoutAMakeStepAMakefileIsSubmissionContent() {
        let names = protectedWorkspaceFilenames(manifest: Self.manifest(makefile: nil))
        #expect(names.isDisjoint(with: ["GNUmakefile", "makefile", "Makefile"]))
    }

    @Test func aSubmissionCannotReplaceOrOutrankTheInstructorsMakefile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-makefile-merge-\(UUID().uuidString)", isDirectory: true)
        let submission = root.appendingPathComponent("submission", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: submission, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "all:\n\tg++ -o main main.cpp\n".write(
            to: workspace.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        for name in ["Makefile", "GNUmakefile", "makefile"] {
            try "all:\n\tcurl attacker.example\n".write(
                to: submission.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "int main() { return 0; }\n".write(
            to: submission.appendingPathComponent("main.cpp"), atomically: true, encoding: .utf8)

        let refused = try mergeDirectoryContents(
            from: submission, into: workspace,
            protected: protectedWorkspaceFilenames(manifest: Self.manifest(makefile: MakefileConfig(target: nil))))

        #expect(Set(refused) == ["Makefile", "GNUmakefile", "makefile"])
        let makefile = try String(contentsOf: workspace.appendingPathComponent("Makefile"), encoding: .utf8)
        #expect(makefile.contains("g++"), "the instructor's makefile was replaced")
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("GNUmakefile").path))
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("makefile").path))
        #expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("main.cpp").path))
    }
}

@Suite(.timeLimit(.minutes(2))) final class SandboxedMakeStepTests {

    /// A work root with two job directories, as the runner lays them out.
    private let workRoot: URL
    private let ownJob: URL
    private let otherJob: URL

    init() throws {
        workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-sandbox-make-\(UUID().uuidString)", isDirectory: true)
        ownJob = workRoot.appendingPathComponent("chickadee_ts_own_\(UUID().uuidString)", isDirectory: true)
        otherJob = workRoot.appendingPathComponent("chickadee_other_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ownJob, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherJob, withIntermediateDirectories: true)
        try "another student's work".write(
            to: otherJob.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: workRoot)
    }

    /// `runMake` never touches the network, so the poller and reporter point
    /// at a port nothing listens on.
    private func daemon(runner: any ScriptRunner) -> WorkerDaemon {
        let base = testURL("http://127.0.0.1:9")
        return WorkerDaemon(
            poller: JobPoller(
                apiBaseURL: base, workerID: "make-sandbox-test", workerSecret: "secret", maxConcurrentJobs: 1,
                profile: nil),
            reporter: Reporter(apiBaseURL: base, workerID: "make-sandbox-test", workerSecret: "secret"),
            runner: runner,
            apiBaseURL: base,
            workerID: "make-sandbox-test",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            testSetupCache: TestSetupCache(
                cacheRoot: workRoot.appendingPathComponent("cache", isDirectory: true)),
            config: .defaults
        )
    }

    @Test(.requiresSandbox, .requiresMake) func aMakefileCommandCannotSeeASiblingJobAndItsOutputStays() async throws {
        try """
        all:
        \t@if [ -e "\(otherJob.path)/secret.txt" ]; then echo "sibling job visible" >&2; exit 1; fi
        \t@echo built > build-output.txt

        """.write(to: ownJob.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)

        try await daemon(runner: SandboxedScriptRunner()).runMake(in: ownJob, target: nil)

        let output = try String(contentsOf: ownJob.appendingPathComponent("build-output.txt"), encoding: .utf8)
        #expect(output.contains("built"), "the make step's output did not stay in the job directory")
    }
}
