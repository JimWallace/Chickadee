// Tests/CoreTests/ZipSubprocessTests.swift
//
// Pins the one zip-subprocess entry point (`runZipProcess`): stdout capture,
// exit-status reporting, and correct results when many zip subprocesses run
// at once.
//
// Replaces `ZipProcessSerializationTests.swift`. That suite pinned the same
// three behaviours plus the process-wide lock and the EFAULT retry that made
// Foundation's `Process` safe to spawn concurrently. Those two mitigations are
// gone with `Process` itself, so their tests are gone; the three behaviours
// below are carried over with their assertions unchanged.
//
// The concurrency test is the one that matters most. It was the regression net
// for the overlapped-drain regime the narrow lock scope created, and it is now
// the regression net for the claim that replaced the lock: that concurrent zip
// spawns need no mutual exclusion at all.
//
// `.serialized` between tests (repo convention for subprocess-spawning
// suites); the concurrency test runs its subprocesses in parallel *within* one
// test body, which is the shape being pinned.

import Core
import Foundation
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
final class ZipSubprocessTests {

    private let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-zipsub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// Creates `name.zip` in the temp dir containing `entries` (filename →
    /// content), returning its path.
    private func makeZip(named name: String, entries: [String: String]) async throws -> String {
        let srcDir = tmpDir.appendingPathComponent("src-\(name)")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        for (filename, content) in entries {
            try content.write(
                to: srcDir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }
        let zipPath = tmpDir.appendingPathComponent("\(name).zip").path
        let result = try await runZipProcess(
            executablePath: "/usr/bin/zip",
            arguments: ["-q", "-r", zipPath, "."],
            workingDirectory: srcDir
        )
        try #require(result.terminationStatus == 0)
        return zipPath
    }

    @Test(.requiresZipTools) func capturesStdoutAndZeroExitStatus() async throws {
        let zipPath = try await makeZip(named: "capture", entries: ["greeting.txt": "hello zip"])

        let list = try await runZipProcess(
            executablePath: "/usr/bin/unzip", arguments: ["-Z1", zipPath])
        #expect(list.terminationStatus == 0)
        let names = String(bytes: list.stdout, encoding: .utf8) ?? ""
        #expect(names.contains("greeting.txt"))

        let extracted = try await runZipProcess(
            executablePath: "/usr/bin/unzip", arguments: ["-p", zipPath, "greeting.txt"])
        #expect(extracted.terminationStatus == 0)
        #expect(String(bytes: extracted.stdout, encoding: .utf8) == "hello zip")
    }

    @Test(.requiresZipTools) func reportsNonZeroExitStatus() async throws {
        let result = try await runZipProcess(
            executablePath: "/usr/bin/unzip",
            arguments: ["-p", tmpDir.appendingPathComponent("absent.zip").path, "nothing.txt"])
        #expect(result.terminationStatus != 0)
    }

    /// Many zip subprocesses at once, each with a distinct expected output.
    /// Every task must read exactly its own child's stdout. A wrong pairing
    /// (crossed pipes, a drain seeing another child's EOF) or a spawn race
    /// fails this loudly.
    @Test(.requiresZipTools) func concurrentZipSubprocessesEachGetTheirOwnOutput() async throws {
        let entryCount = 12
        var entries: [String: String] = [:]
        for index in 0..<entryCount {
            entries["entry-\(index).txt"] = "content-\(index)"
        }
        let zipPath = try await makeZip(named: "concurrent", entries: entries)

        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for index in 0..<entryCount {
                group.addTask {
                    let result = try await runZipProcess(
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
}
