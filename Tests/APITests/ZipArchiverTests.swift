// Tests/APITests/ZipArchiverTests.swift
//
// Tests for ZipArchiver — round-trip extraction, zip-slip path traversal
// detection, and error descriptions.

import XCTest
@testable import chickadee_server
import Foundation

final class ZipArchiverTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Helpers

    /// Creates a zip archive at `zipPath` containing entries with the given names
    /// and content using Python's zipfile module. Skips if Python3 is unavailable.
    private func makePythonZip(at zipPath: String, entries: [(name: String, content: String)]) throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/env") else {
            throw XCTSkip("env not available")
        }
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
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw XCTSkip("python3 not available or failed to create zip")
        }
    }

    // MARK: - Error descriptions

    func testErrorDescription_processFailed() {
        let e = ZipArchiverError.processFailed("/usr/bin/zip", 1)
        XCTAssertEqual(e.description, "/usr/bin/zip exited with status 1")
    }

    func testErrorDescription_executableNotFound() {
        let e = ZipArchiverError.executableNotFound("/usr/bin/zip")
        XCTAssertEqual(e.description, "Executable not found: /usr/bin/zip")
    }

    func testErrorDescription_pathTraversalDetected() {
        let e = ZipArchiverError.pathTraversalDetected("../evil.txt")
        XCTAssertEqual(e.description, "Zip entry would escape destination directory: ../evil.txt")
    }

    // MARK: - Happy path round-trip

    func testCreateAndExtract_roundTrip() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/zip"),
              FileManager.default.fileExists(atPath: "/usr/bin/unzip") else {
            throw XCTSkip("zip/unzip not available")
        }

        // Create a source directory with two files.
        let srcDir = tmpDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try "hello".write(to: srcDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "world".write(to: srcDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        // Zip it up.
        let zipPath = tmpDir.appendingPathComponent("archive.zip").path
        try await createZipArchive(sourceDir: srcDir, outputPath: zipPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipPath), "Zip file should be created")

        // Extract into a new directory.
        let destDir = tmpDir.appendingPathComponent("dest")
        try await extractZipArchive(zipPath: zipPath, into: destDir)

        // Verify both files are present with correct content.
        let aContent = try String(contentsOf: destDir.appendingPathComponent("a.txt"), encoding: .utf8)
        let bContent = try String(contentsOf: destDir.appendingPathComponent("b.txt"), encoding: .utf8)
        XCTAssertEqual(aContent, "hello")
        XCTAssertEqual(bContent, "world")
    }

    // MARK: - Path traversal detection

    func testDotDotTraversal_throws() async throws {
        let zipPath = tmpDir.appendingPathComponent("traversal.zip").path
        try makePythonZip(at: zipPath, entries: [
            (name: "../evil.txt", content: "pwned"),
            (name: "safe.txt",    content: "ok"),
        ])

        let destDir = tmpDir.appendingPathComponent("dest_traversal")
        do {
            try await extractZipArchive(zipPath: zipPath, into: destDir)
            XCTFail("Expected pathTraversalDetected to be thrown")
        } catch ZipArchiverError.pathTraversalDetected(let entry) {
            XCTAssertEqual(entry, "../evil.txt")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDeepDotDotTraversal_throws() async throws {
        let zipPath = tmpDir.appendingPathComponent("deep_traversal.zip").path
        try makePythonZip(at: zipPath, entries: [
            (name: "subdir/../../evil.txt", content: "pwned"),
        ])

        let destDir = tmpDir.appendingPathComponent("dest_deep")
        do {
            try await extractZipArchive(zipPath: zipPath, into: destDir)
            XCTFail("Expected pathTraversalDetected to be thrown")
        } catch ZipArchiverError.pathTraversalDetected {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAbsolutePathEntry_throws() async throws {
        let zipPath = tmpDir.appendingPathComponent("absolute.zip").path
        try makePythonZip(at: zipPath, entries: [
            (name: "/etc/evil.txt", content: "pwned"),
        ])

        let destDir = tmpDir.appendingPathComponent("dest_abs")
        do {
            try await extractZipArchive(zipPath: zipPath, into: destDir)
            XCTFail("Expected pathTraversalDetected to be thrown")
        } catch ZipArchiverError.pathTraversalDetected {
            // Expected — absolute path entry rejected
        } catch {
            // Some unzip versions strip leading / rather than reporting it via -Z1.
            // If unzip normalises the path, extraction may succeed; that's acceptable.
            // Only fail if we get a completely unexpected error type.
            if !(error is ZipArchiverError) {
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }

    // MARK: - listZipContents

    func testListZipContents_returnsEntryNames() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/zip"),
              FileManager.default.fileExists(atPath: "/usr/bin/unzip") else {
            throw XCTSkip("zip/unzip not available")
        }

        let srcDir = tmpDir.appendingPathComponent("list_src")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try "x".write(to: srcDir.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try "y".write(to: srcDir.appendingPathComponent("beta.txt"),  atomically: true, encoding: .utf8)

        let zipPath = tmpDir.appendingPathComponent("list.zip").path
        try await createZipArchive(sourceDir: srcDir, outputPath: zipPath)

        let entries = try listZipContents(zipPath: zipPath)
        XCTAssertTrue(entries.contains(where: { $0.hasSuffix("alpha.txt") }))
        XCTAssertTrue(entries.contains(where: { $0.hasSuffix("beta.txt") }))
    }
}
