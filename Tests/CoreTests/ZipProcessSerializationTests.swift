// Tests/CoreTests/ZipProcessSerializationTests.swift
//
// Pins the one sync zip-subprocess entry point (`runZipProcessCapturingStdout`):
// stdout capture, exit-status reporting, and — the property the narrow lock
// scope exists for — correct results when many zip subprocesses run at once.
// The process-wide lock covers construction + spawn only, so concurrent
// children overlap their drains and waits; the concurrency test below is the
// regression net for that overlapped regime.
//
// `.serialized` between tests (repo convention for subprocess-spawning
// suites); the concurrency test runs its subprocesses in parallel *within*
// one test body, which is the shape being pinned.

import Core
import Foundation
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
final class ZipProcessSerializationTests {

    private let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-ziplock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private var zipToolsPresent: Bool {
        FileManager.default.fileExists(atPath: "/usr/bin/zip")
            && FileManager.default.fileExists(atPath: "/usr/bin/unzip")
    }

    /// Creates `name.zip` in the temp dir containing `entries` (filename →
    /// content), returning its path.
    private func makeZip(named name: String, entries: [String: String]) throws -> String {
        let srcDir = tmpDir.appendingPathComponent("src-\(name)")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        for (filename, content) in entries {
            try content.write(
                to: srcDir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }
        let zipPath = tmpDir.appendingPathComponent("\(name).zip").path
        let result = try runZipProcessCapturingStdout(
            executablePath: "/usr/bin/zip",
            arguments: ["-q", "-r", zipPath, "."],
            workingDirectory: srcDir
        )
        try #require(result.terminationStatus == 0)
        return zipPath
    }

    @Test func capturesStdoutAndZeroExitStatus() throws {
        guard zipToolsPresent else { return }
        let zipPath = try makeZip(named: "capture", entries: ["greeting.txt": "hello zip"])

        let list = try runZipProcessCapturingStdout(
            executablePath: "/usr/bin/unzip",
            arguments: ["-Z1", zipPath]
        )
        #expect(list.terminationStatus == 0)
        let names = try #require(String(bytes: list.stdout, encoding: .utf8))
        #expect(names.contains("greeting.txt"))

        let extracted = try runZipProcessCapturingStdout(
            executablePath: "/usr/bin/unzip",
            arguments: ["-p", zipPath, "greeting.txt"]
        )
        #expect(extracted.terminationStatus == 0)
        #expect(String(bytes: extracted.stdout, encoding: .utf8) == "hello zip")
    }

    @Test func reportsNonZeroExitStatus() throws {
        guard zipToolsPresent else { return }
        let missing = tmpDir.appendingPathComponent("does-not-exist.zip").path
        let result = try runZipProcessCapturingStdout(
            executablePath: "/usr/bin/unzip",
            arguments: ["-Z1", missing]
        )
        #expect(result.terminationStatus != 0)
    }

    /// Many zip subprocesses at once, each with a distinct expected output.
    /// With the lock released before the drain, children run concurrently;
    /// every task must still read exactly its own child's stdout. A wrong
    /// pairing (crossed pipes, a drain seeing another child's EOF) or a
    /// revived spawn race fails this loudly.
    @Test func concurrentZipSubprocessesEachGetTheirOwnOutput() async throws {
        guard zipToolsPresent else { return }
        let entryCount = 12
        var entries: [String: String] = [:]
        for index in 0..<entryCount {
            entries["entry-\(index).txt"] = "content-\(index)"
        }
        let zipPath = try makeZip(named: "concurrent", entries: entries)

        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for index in 0..<entryCount {
                group.addTask {
                    let result = try runZipProcessCapturingStdout(
                        executablePath: "/usr/bin/unzip",
                        arguments: ["-p", zipPath, "entry-\(index).txt"]
                    )
                    try #require(result.terminationStatus == 0)
                    let output = try #require(String(bytes: result.stdout, encoding: .utf8))
                    return (index, output)
                }
            }
            var seen = 0
            for try await (index, output) in group {
                #expect(output == "content-\(index)")
                seen += 1
            }
            #expect(seen == entryCount)
        }
    }

    // MARK: - The process-wide lock

    /// Kills the two `RemoveSideEffects` survivors from the 2026-08-19 sweep
    /// (run 32265903112): the `zipProcessLock.lock()` inside
    /// `withZipProcessLock`, and the one that IS `acquireZipProcessLock()`.
    ///
    /// Deleting either leaves the API shape intact and every other test in this
    /// suite green — the concurrency test above passes precisely because the
    /// children are meant to overlap — while removing the mutual exclusion the
    /// file exists for. What comes back is the Foundation `Process` spawn race:
    /// an intermittent `NSPOSIXErrorDomain Code=14` on an unrelated pull
    /// request, or the SIGSEGV variant that no retry can catch.
    ///
    /// The assertion runs in the safe direction. Under the real lock the second
    /// caller can NEVER enter while the first holds it, whatever the machine is
    /// doing; a slow scheduler can only make this test pass spuriously, never
    /// fail spuriously.
    @Test func aHeldLockKeepsEveryOtherZipSpawnOut() {
        let entered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)

        // NSLock is thread-bound, so both halves use real threads: a Swift
        // concurrency task may resume on a different thread than it suspended
        // on, which would unlock from a thread that never locked.
        acquireZipProcessLock()
        Thread.detachNewThread {
            withZipProcessLock { _ = entered.signal() }
            finished.signal()
        }
        let enteredWhileHeld = entered.wait(timeout: .now() + 1.0) == .success
        releaseZipProcessLock()

        #expect(
            !enteredWhileHeld,
            "a second zip spawn entered the serialized window while the lock was held")
        #expect(
            finished.wait(timeout: .now() + 10) == .success,
            "the waiting spawn never ran after the lock was released")
    }

    // MARK: - The EFAULT retry

    /// A `Process` that never spawns: it throws a chosen error for its first
    /// `failures` attempts and counts every call.
    ///
    /// A real EFAULT cannot be provoked on demand — it is the residue of a race
    /// — so the retry's *condition* can only be pinned by supplying the error.
    /// Overriding `run()` also makes the attempt count observable, which is the
    /// only difference between retrying and not when both paths end up throwing
    /// the same error.
    /// `@unchecked Sendable` because `Process` already claims it and Swift
    /// requires a subclass to restate the claim. Nothing here is shared across
    /// threads: each instance is created, run, and read inside one test body.
    private final class ThrowingProcess: Process, @unchecked Sendable {
        private let error: NSError
        private let failures: Int
        private(set) var attempts = 0

        init(throwing error: NSError, times failures: Int) {
            self.error = error
            self.failures = failures
            super.init()
        }

        override func run() throws {
            attempts += 1
            if attempts <= failures { throw error }
        }
    }

    private func posixEFAULT() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(EFAULT))
    }

    @Test func aTransientEFAULTIsRetriedAndSucceeds() throws {
        let proc = ThrowingProcess(throwing: posixEFAULT(), times: 1)
        try runProcessWithEFAULTRetry(proc)
        #expect(proc.attempts == 2)
    }

    @Test func aPersistentEFAULTIsRetriedExactlyOnceThenPropagates() {
        let proc = ThrowingProcess(throwing: posixEFAULT(), times: .max)
        #expect(throws: (any Error).self) { try runProcessWithEFAULTRetry(proc) }
        #expect(proc.attempts == 2, "the retry is once, not a loop")
    }

    /// Kills the `code !=` half of the `RelationalOperatorReplacement` pair and
    /// the `ChangeLogicalConnector`: both make a non-EFAULT POSIX failure
    /// retryable.
    ///
    /// Retrying the wrong error is not free. `runProcessWithEFAULTRetry` is
    /// called with a `Process` whose pipes are already wired, so a second
    /// `run()` after a genuine failure re-spawns against them — and the caller
    /// waits out a 10 ms sleep per attempt on a path that services notebook
    /// opens and dashboard page views.
    @Test func anotherPOSIXFailureIsNotRetried() {
        let proc = ThrowingProcess(
            throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)), times: .max)
        #expect(throws: (any Error).self) { try runProcessWithEFAULTRetry(proc) }
        #expect(proc.attempts == 1)
    }

    /// Kills the `domain !=` half and, again, the `ChangeLogicalConnector`.
    /// Error code 14 means something different in every domain — it is
    /// `NSFileWriteUnknownError` in `NSCocoaErrorDomain` — so the domain is
    /// what makes the number mean EFAULT at all.
    @Test func theSameCodeInAnotherDomainIsNotRetried() {
        let proc = ThrowingProcess(
            throwing: NSError(domain: NSCocoaErrorDomain, code: Int(EFAULT)), times: .max)
        #expect(throws: (any Error).self) { try runProcessWithEFAULTRetry(proc) }
        #expect(proc.attempts == 1)
    }

}
