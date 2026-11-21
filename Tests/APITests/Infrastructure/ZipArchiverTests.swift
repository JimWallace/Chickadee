// Tests/APITests/Infrastructure/ZipArchiverTests.swift
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

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing

@testable import APIServer

// final class so deinit can remove the per-test temp directory.
@Suite(.serialized, .timeLimit(.minutes(2)))
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

    /// Creates a zip archive at `zipPath` using Python's zipfile module, which
    /// can write entry names (`../x`, `/abs`) that `zip` refuses. A test that
    /// calls it carries `.requiresPython3`.
    private func makePythonZip(at zipPath: String, entries: [(name: String, content: String)]) async throws {
        let entriesCode = entries.map { e in
            "z.writestr(\(e.name.debugDescription), \(e.content.debugDescription))"
        }.joined(separator: "\n    ")
        let script = """
            import zipfile
            with zipfile.ZipFile('\(zipPath)', 'w') as z:
                \(entriesCode)
            """
        let run = try await runTool(["python3", "-c", script])
        guard run.succeeded else { throw IssueRecorded("python3 could not write \(zipPath)") }
    }

    // MARK: - Error descriptions

    @Test func errorDescriptionProcessFailed() async {
        let e = ZipArchiverError.processFailed("/usr/bin/zip", 1)
        #expect(e.description == "/usr/bin/zip exited with status 1")
    }

    @Test func errorDescriptionExecutableNotFound() async {
        let e = ZipArchiverError.executableNotFound("/usr/bin/zip")
        #expect(e.description == "Executable not found: /usr/bin/zip")
    }

    @Test func errorDescriptionPathTraversalDetected() async {
        let e = ZipArchiverError.pathTraversalDetected("../evil.txt")
        #expect(e.description == "Zip entry would escape destination directory: ../evil.txt")
    }

    // MARK: - Happy path round-trip

    @Test(.requiresZipTools) func createAndExtractRoundTrip() async throws {
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

    // MARK: - Large archive (regression: unread-pipe deadlock)

    /// `zip -r` emits one "adding: …" line per file. When the discarded child
    /// output was an in-memory `Pipe` nobody drained, an archive whose output
    /// exceeded the ~64 KB OS pipe buffer deadlocked — `zip` blocked on write,
    /// never exited, and `runZipProcess`'s continuation never resumed. That
    /// hung a data-heavy personal-data export forever in `pending`. Enough
    /// files to blow past the buffer must still complete.
    @Test(.requiresZipTools, .timeLimit(.minutes(1)))
    func createZipArchive_manyFiles_doesNotDeadlock() async throws {
        let srcDir = tmpDir.appendingPathComponent("many")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        // ~3000 realistically-named files ≈ 180 KB of verbose zip output,
        // comfortably past the 64 KB buffer that triggered the hang.
        let fileCount = 3000
        for i in 0..<fileCount {
            let name = String(cFormat: "submissions_sub_%08d_results_%d.json", i, i)
            try Data("{}\n".utf8).write(to: srcDir.appendingPathComponent(name))
        }

        let zipPath = tmpDir.appendingPathComponent("many.zip").path
        try await createZipArchive(sourceDir: srcDir, outputPath: zipPath)
        #expect(FileManager.default.fileExists(atPath: zipPath))

        let entries = try await listZipContents(zipPath: zipPath)
        #expect(entries.count >= fileCount, "every file should be archived")
    }

    // MARK: - Path traversal detection

    @Test(.requiresPython3) func dotDotTraversalThrows() async throws {
        let zipPath = tmpDir.appendingPathComponent("traversal.zip").path
        try await makePythonZip(
            at: zipPath,
            entries: [
                (name: "../evil.txt", content: "pwned"),
                (name: "safe.txt", content: "ok"),
            ])

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

    @Test(.requiresPython3) func deepDotDotTraversalThrows() async throws {
        let zipPath = tmpDir.appendingPathComponent("deep_traversal.zip").path
        try await makePythonZip(
            at: zipPath,
            entries: [
                (name: "subdir/../../evil.txt", content: "pwned")
            ])

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

    @Test(.requiresPython3) func absolutePathEntryThrows() async throws {
        let zipPath = tmpDir.appendingPathComponent("absolute.zip").path
        try await makePythonZip(
            at: zipPath,
            entries: [
                (name: "/etc/evil.txt", content: "pwned")
            ])

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

    @Test(.requiresZipTools) func listZipContentsReturnsEntryNames() async throws {
        let srcDir = tmpDir.appendingPathComponent("list_src")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try "x".write(to: srcDir.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try "y".write(to: srcDir.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)

        let zipPath = tmpDir.appendingPathComponent("list.zip").path
        try await createZipArchive(sourceDir: srcDir, outputPath: zipPath)

        let entries = try await listZipContents(zipPath: zipPath)
        #expect(entries.contains { $0.hasSuffix("alpha.txt") })
        #expect(entries.contains { $0.hasSuffix("beta.txt") })
    }

    // MARK: - readScriptFromZip

    @Test(.requiresPython3) func readScriptFromZipReturnsCorrectContent() async throws {
        let zipPath = tmpDir.appendingPathComponent("read_test.zip").path
        try await makePythonZip(
            at: zipPath,
            entries: [
                (name: "test_foo.py", content: "def foo():\n    pass\n")
            ])

        #expect(await readScriptFromZip(zipPath: zipPath, filename: "test_foo.py") == "def foo():\n    pass\n")
    }

    @Test(.requiresPython3) func readScriptFromZipReturnsNilForMissingEntry() async throws {
        let zipPath = tmpDir.appendingPathComponent("read_missing.zip").path
        try await makePythonZip(
            at: zipPath,
            entries: [
                (name: "test_a.py", content: "pass\n")
            ])

        #expect(await readScriptFromZip(zipPath: zipPath, filename: "does_not_exist.py") == nil)
    }

    // MARK: - updateScriptInZip

    @Test(.requiresZipTools, .requiresPython3) func updateScriptInZipReplacesExistingFile() async throws {
        let zipPath = tmpDir.appendingPathComponent("update_test.zip").path
        try await makePythonZip(
            at: zipPath,
            entries: [
                (name: "test_bar.py", content: "# old\n")
            ])

        try await updateScriptInZip(zipPath: zipPath, filename: "test_bar.py", content: "# new\n")

        await #expect(readScriptFromZip(zipPath: zipPath, filename: "test_bar.py") == "# new\n")
    }

    @Test(.requiresZipTools, .requiresPython3) func updateScriptInZipAddsNewFile() async throws {
        let zipPath = tmpDir.appendingPathComponent("add_test.zip").path
        try await makePythonZip(
            at: zipPath,
            entries: [
                (name: "existing.py", content: "pass\n")
            ])

        try await updateScriptInZip(zipPath: zipPath, filename: "new_file.py", content: "# added\n")

        await #expect(readScriptFromZip(zipPath: zipPath, filename: "existing.py") != nil)
        await #expect(readScriptFromZip(zipPath: zipPath, filename: "new_file.py") == "# added\n")
    }

    @Test(.requiresZipTools, .requiresPython3) func updateScriptInZipPreservesOtherFiles() async throws {
        let zipPath = tmpDir.appendingPathComponent("preserve_test.zip").path
        try await makePythonZip(
            at: zipPath,
            entries: [
                (name: "a.py", content: "# a\n"),
                (name: "b.py", content: "# b\n"),
                (name: "c.py", content: "# c\n"),
            ])

        try await updateScriptInZip(zipPath: zipPath, filename: "b.py", content: "# b updated\n")

        await #expect(readScriptFromZip(zipPath: zipPath, filename: "a.py") == "# a\n")
        await #expect(readScriptFromZip(zipPath: zipPath, filename: "b.py") == "# b updated\n")
        await #expect(readScriptFromZip(zipPath: zipPath, filename: "c.py") == "# c\n")
    }

    // MARK: - removeScriptFromZip

    @Test(.requiresZipTools, .requiresPython3) func removeScriptFromZipRemovesFile() async throws {
        let zipPath = tmpDir.appendingPathComponent("remove_test.zip").path
        try await makePythonZip(
            at: zipPath,
            entries: [
                (name: "keep.py", content: "pass\n"),
                (name: "remove_me.py", content: "pass\n"),
            ])

        try await removeScriptFromZip(zipPath: zipPath, filename: "remove_me.py")

        await #expect(readScriptFromZip(zipPath: zipPath, filename: "remove_me.py") == nil)
        await #expect(readScriptFromZip(zipPath: zipPath, filename: "keep.py") != nil)
    }

    @Test(.requiresZipTools, .requiresPython3) func removeScriptFromZipThrowsForMissingFile() async throws {
        let zipPath = tmpDir.appendingPathComponent("remove_missing.zip").path
        try await makePythonZip(
            at: zipPath,
            entries: [
                (name: "test_a.py", content: "pass\n")
            ])

        let error = try await #require(throws: ScriptZipError.self) {
            try await removeScriptFromZip(zipPath: zipPath, filename: "does_not_exist.py")
        }
        guard case .fileNotFound(let name) = error else {
            Issue.record("Expected fileNotFound, got \(error)")
            return
        }
        #expect(name == "does_not_exist.py")
    }
}
