// Tests/WorkerTests/NativeScriptExecutorHidingTests.swift
//
// While one suite script runs, the executor asks the runner to hide the job's
// other suite scripts: a submission runs inside its test's process, so a public
// test could otherwise read the release and secret test scripts beside it
// (docs/grading-integrity.md, phase 2). Support files are never in the list.

import Foundation
import Testing

@testable import chickadee_runner

@Suite final class NativeScriptExecutorHidingTests {

    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-hiding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["publictest_a.py", "releasetest_b.py", "secrettest_c.py", "answer_key.csv"] {
            try "".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func executor(suite: [String]) -> NativeScriptExecutor {
        NativeScriptExecutor(runner: UnsandboxedScriptRunner(), workDir: dir, suiteScripts: suite)
    }

    @Test func theOtherSuiteScriptsAreHiddenAndTheRunningOneIsNot() {
        let hidden = executor(suite: ["publictest_a.py", "releasetest_b.py", "secrettest_c.py"])
            .scriptsHidden(whileRunning: "publictest_a.py")
            .map(\.lastPathComponent)
        #expect(hidden == ["releasetest_b.py", "secrettest_c.py"])
    }

    @Test func supportFilesMissingScriptsAndRepeatsAreNotListed() {
        let hidden = executor(suite: ["publictest_a.py", "secrettest_c.py", "secrettest_c.py", "gone.py"])
            .scriptsHidden(whileRunning: "publictest_a.py")
            .map(\.lastPathComponent)
        #expect(hidden == ["secrettest_c.py"])
    }

    @Test func anExecutorWithNoSuiteHidesNothing() {
        #expect(executor(suite: []).scriptsHidden(whileRunning: "publictest_a.py").isEmpty)
    }
}
