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
}
