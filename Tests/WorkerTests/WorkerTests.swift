import XCTest
@testable import Worker
import Foundation

final class WorkerTests: XCTestCase {

    // MARK: - Setup

    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-worker-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeScript(_ body: String, name: String = "test.sh") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: url.path
        )
        return url
    }

    // MARK: - UnsandboxedScriptRunner: exit code mapping

    func testScriptExitZeroReportsExitCodeZero() async throws {
        let script = try writeScript("#!/bin/sh\nexit 0")
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 5)
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertFalse(output.timedOut)
    }

    func testScriptExitOneReportsExitCodeOne() async throws {
        let script = try writeScript("#!/bin/sh\nexit 1")
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 5)
        XCTAssertEqual(output.exitCode, 1)
        XCTAssertFalse(output.timedOut)
    }

    func testScriptExitTwoReportsExitCodeTwo() async throws {
        let script = try writeScript("#!/bin/sh\nexit 2")
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 5)
        XCTAssertEqual(output.exitCode, 2)
        XCTAssertFalse(output.timedOut)
    }

    // MARK: - UnsandboxedScriptRunner: output capture

    func testStdoutIsCaptured() async throws {
        let script = try writeScript("#!/bin/sh\necho 'hello world'\nexit 0")
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 5)
        XCTAssertTrue(output.stdout.contains("hello world"))
    }

    func testStderrIsCaptured() async throws {
        let script = try writeScript("#!/bin/sh\necho 'oops' >&2\nexit 0")
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 5)
        XCTAssertTrue(output.stderr.contains("oops"))
    }

    func testStdoutAndStderrAreSeparate() async throws {
        let script = try writeScript("#!/bin/sh\necho 'out'\necho 'err' >&2\nexit 0")
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 5)
        XCTAssertTrue(output.stdout.contains("out"))
        XCTAssertFalse(output.stdout.contains("err"))
        XCTAssertTrue(output.stderr.contains("err"))
        XCTAssertFalse(output.stderr.contains("out"))
    }

    // MARK: - UnsandboxedScriptRunner: timeout

    func testScriptTimesOut() async throws {
        let script = try writeScript("#!/bin/sh\nsleep 60\nexit 0")
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 1)
        XCTAssertTrue(output.timedOut, "Script sleeping 60s should time out with a 1s limit")
        XCTAssertEqual(output.exitCode, -1)
    }

    // MARK: - UnsandboxedScriptRunner: working directory

    func testWorkDirIsSetCorrectly() async throws {
        let script = try writeScript("#!/bin/sh\ntouch marker.txt\nexit 0")
        let runner = UnsandboxedScriptRunner()
        _ = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 5)
        let markerPath = tmpDir.appendingPathComponent("marker.txt").path
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: markerPath),
            "Script should create marker.txt in the supplied working directory"
        )
    }

    // MARK: - ExponentialBackoff

    func testBackoffResetsToInitial() {
        var backoff = ExponentialBackoff(initial: .seconds(1), max: .seconds(64))
        for _ in 0..<5 { _ = backoff.next() }
        backoff.reset()
        // After reset the next jittered value must be <= 2s (double of the 1s initial).
        let afterReset = backoff.next()
        XCTAssertLessThanOrEqual(
            afterReset.components.seconds, 2,
            "After reset, next delay should be at most 2s"
        )
    }

    func testBackoffRespectsMaximum() {
        var backoff = ExponentialBackoff(initial: .seconds(1), max: .seconds(4))
        for _ in 0..<20 { _ = backoff.next() }
        let capped = backoff.next()
        XCTAssertLessThanOrEqual(
            capped.components.seconds, 4,
            "Backoff should never exceed max"
        )
    }
}
