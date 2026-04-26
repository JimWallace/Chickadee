// Tests/APITests/ZipArchiverTests.swift
//
// Tests for ZipArchiver — round-trip extraction, zip-slip path traversal
// detection, and error descriptions.
//
// `.serialized`: every test in this suite spawns one or more `Process`
// instances (zip / unzip / python3) and reads from `Pipe`s.  Foundation's
// posix_spawn implementation has a known race under concurrent invocation
// that surfaces as `NSPOSIXErrorDomain Code=14 "Bad address"` (EFAULT) at
// ~5% rate when nine of these tests run in parallel within the suite.
// Serializing the suite eliminates the within-suite race while still
// allowing other suites to run in parallel.

import Testing
@testable import chickadee_server
import Fluent
import Foundation

// final class so deinit can remove the per-test temp directory.
@Suite(.serialized)
final class ZipArchiverTests {

    private let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Helpers

    /// Creates a zip archive at `zipPath` using Python's zipfile module.
    /// Returns `false` (and leaves the test a silent no-op) if python3 is
    /// not available; tests that call this should `guard` on the return value.
    private func makePythonZip(at zipPath: String, entries: [(name: String, content: String)]) throws -> Bool {
        let entriesCode = entries.map { e in
            "z.writestr(\(e.name.debugDescription), \(e.content.debugDescription))"
        }.joined(separator: "\n    ")
        let script = """
import zipfile
with zipfile.ZipFile('\(zipPath)', 'w') as z:
    \(entriesCode)
"""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", "-c", script]
        proc.standardOutput = Pipe()
        proc.standardError  = Pipe()
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    // MARK: - Error descriptions

    @Test func errorDescriptionProcessFailed() {
        let e = ZipArchiverError.processFailed("/usr/bin/zip", 1)
        #expect(e.description == "/usr/bin/zip exited with status 1")
    }

    @Test func errorDescriptionExecutableNotFound() {
        let e = ZipArchiverError.executableNotFound("/usr/bin/zip")
        #expect(e.description == "Executable not found: /usr/bin/zip")
    }

    @Test func errorDescriptionPathTraversalDetected() {
        let e = ZipArchiverError.pathTraversalDetected("../evil.txt")
        #expect(e.description == "Zip entry would escape destination directory: ../evil.txt")
    }

    // MARK: - Happy path round-trip

    @Test func createAndExtractRoundTrip() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/zip"),
              FileManager.default.fileExists(atPath: "/usr/bin/unzip") else { return }

        let srcDir = tmpDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try "hello".write(to: srcDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "world".write(to: srcDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let zipPath = tmpDir.appendingPathComponent("archive.zip").path
        try await createZipArchive(sourceDir: srcDir, outputPath: zipPath)
        #expect(FileManager.default.fileExists(atPath: zipPath), "Zip file should be created")

        let destDir = tmpDir.appendingPathComponent("dest")
        try await extractZipArchive(zipPath: zipPath, into: destDir)

        let aContent = try String(contentsOf: destDir.appendingPathComponent("a.txt"), encoding: .utf8)
        let bContent = try String(contentsOf: destDir.appendingPathComponent("b.txt"), encoding: .utf8)
        #expect(aContent == "hello")
        #expect(bContent == "world")
    }

    // MARK: - Path traversal detection

    @Test func dotDotTraversalThrows() async throws {
        let zipPath = tmpDir.appendingPathComponent("traversal.zip").path
        guard try makePythonZip(at: zipPath, entries: [
            (name: "../evil.txt", content: "pwned"),
            (name: "safe.txt",    content: "ok"),
        ]) else { return }

        let destDir = tmpDir.appendingPathComponent("dest_traversal")
        do {
            try await extractZipArchive(zipPath: zipPath, into: destDir)
            Issue.record("Expected pathTraversalDetected to be thrown")
        } catch ZipArchiverError.pathTraversalDetected(let entry) {
            #expect(entry == "../evil.txt")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func deepDotDotTraversalThrows() async throws {
        let zipPath = tmpDir.appendingPathComponent("deep_traversal.zip").path
        guard try makePythonZip(at: zipPath, entries: [
            (name: "subdir/../../evil.txt", content: "pwned"),
        ]) else { return }

        let destDir = tmpDir.appendingPathComponent("dest_deep")
        do {
            try await extractZipArchive(zipPath: zipPath, into: destDir)
            Issue.record("Expected pathTraversalDetected to be thrown")
        } catch ZipArchiverError.pathTraversalDetected {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func absolutePathEntryThrows() async throws {
        let zipPath = tmpDir.appendingPathComponent("absolute.zip").path
        guard try makePythonZip(at: zipPath, entries: [
            (name: "/etc/evil.txt", content: "pwned"),
        ]) else { return }

        let destDir = tmpDir.appendingPathComponent("dest_abs")
        do {
            try await extractZipArchive(zipPath: zipPath, into: destDir)
            Issue.record("Expected error to be thrown")
        } catch ZipArchiverError.pathTraversalDetected {
            // Expected — absolute path entry rejected
        } catch is ZipArchiverError {
            // Also acceptable — some unzip versions strip the leading /
            // rather than surfacing it via the entry list; still a ZipArchiverError.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - listZipContents

    @Test func listZipContentsReturnsEntryNames() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/zip"),
              FileManager.default.fileExists(atPath: "/usr/bin/unzip") else { return }

        let srcDir = tmpDir.appendingPathComponent("list_src")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try "x".write(to: srcDir.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try "y".write(to: srcDir.appendingPathComponent("beta.txt"),  atomically: true, encoding: .utf8)

        let zipPath = tmpDir.appendingPathComponent("list.zip").path
        try await createZipArchive(sourceDir: srcDir, outputPath: zipPath)

        let entries = try listZipContents(zipPath: zipPath)
        #expect(entries.contains { $0.hasSuffix("alpha.txt") })
        #expect(entries.contains { $0.hasSuffix("beta.txt") })
    }

    // MARK: - readScriptFromZip

    @Test func readScriptFromZipReturnsCorrectContent() throws {
        let zipPath = tmpDir.appendingPathComponent("read_test.zip").path
        guard try makePythonZip(at: zipPath, entries: [
            (name: "test_foo.py", content: "def foo():\n    pass\n")
        ]) else { return }

        #expect(readScriptFromZip(zipPath: zipPath, filename: "test_foo.py") == "def foo():\n    pass\n")
    }

    @Test func readScriptFromZipReturnsNilForMissingEntry() throws {
        let zipPath = tmpDir.appendingPathComponent("read_missing.zip").path
        guard try makePythonZip(at: zipPath, entries: [
            (name: "test_a.py", content: "pass\n")
        ]) else { return }

        #expect(readScriptFromZip(zipPath: zipPath, filename: "does_not_exist.py") == nil)
    }

    // MARK: - updateScriptInZip

    @Test func updateScriptInZipReplacesExistingFile() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/zip"),
              FileManager.default.fileExists(atPath: "/usr/bin/unzip") else { return }
        let zipPath = tmpDir.appendingPathComponent("update_test.zip").path
        guard try makePythonZip(at: zipPath, entries: [
            (name: "test_bar.py", content: "# old\n")
        ]) else { return }

        try updateScriptInZip(zipPath: zipPath, filename: "test_bar.py", content: "# new\n")

        #expect(readScriptFromZip(zipPath: zipPath, filename: "test_bar.py") == "# new\n")
    }

    @Test func updateScriptInZipAddsNewFile() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/zip"),
              FileManager.default.fileExists(atPath: "/usr/bin/unzip") else { return }
        let zipPath = tmpDir.appendingPathComponent("add_test.zip").path
        guard try makePythonZip(at: zipPath, entries: [
            (name: "existing.py", content: "pass\n")
        ]) else { return }

        try updateScriptInZip(zipPath: zipPath, filename: "new_file.py", content: "# added\n")

        #expect(readScriptFromZip(zipPath: zipPath, filename: "existing.py") != nil)
        #expect(readScriptFromZip(zipPath: zipPath, filename: "new_file.py") == "# added\n")
    }

    @Test func updateScriptInZipPreservesOtherFiles() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/zip"),
              FileManager.default.fileExists(atPath: "/usr/bin/unzip") else { return }
        let zipPath = tmpDir.appendingPathComponent("preserve_test.zip").path
        guard try makePythonZip(at: zipPath, entries: [
            (name: "a.py", content: "# a\n"),
            (name: "b.py", content: "# b\n"),
            (name: "c.py", content: "# c\n")
        ]) else { return }

        try updateScriptInZip(zipPath: zipPath, filename: "b.py", content: "# b updated\n")

        #expect(readScriptFromZip(zipPath: zipPath, filename: "a.py") == "# a\n")
        #expect(readScriptFromZip(zipPath: zipPath, filename: "b.py") == "# b updated\n")
        #expect(readScriptFromZip(zipPath: zipPath, filename: "c.py") == "# c\n")
    }

    // MARK: - removeScriptFromZip

    @Test func removeScriptFromZipRemovesFile() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/zip"),
              FileManager.default.fileExists(atPath: "/usr/bin/unzip") else { return }
        let zipPath = tmpDir.appendingPathComponent("remove_test.zip").path
        guard try makePythonZip(at: zipPath, entries: [
            (name: "keep.py",      content: "pass\n"),
            (name: "remove_me.py", content: "pass\n")
        ]) else { return }

        try removeScriptFromZip(zipPath: zipPath, filename: "remove_me.py")

        #expect(readScriptFromZip(zipPath: zipPath, filename: "remove_me.py") == nil)
        #expect(readScriptFromZip(zipPath: zipPath, filename: "keep.py") != nil)
    }

    @Test func removeScriptFromZipThrowsForMissingFile() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/zip"),
              FileManager.default.fileExists(atPath: "/usr/bin/unzip") else { return }
        let zipPath = tmpDir.appendingPathComponent("remove_missing.zip").path
        guard try makePythonZip(at: zipPath, entries: [
            (name: "test_a.py", content: "pass\n")
        ]) else { return }

        let error = try #require(throws: ScriptZipError.self) {
            try removeScriptFromZip(zipPath: zipPath, filename: "does_not_exist.py")
        }
        guard case .fileNotFound(let name) = error else {
            Issue.record("Expected fileNotFound, got \(error)")
            return
        }
        #expect(name == "does_not_exist.py")
    }
}
