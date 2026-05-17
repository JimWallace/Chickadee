// Tests/APITests/ZipUploadValidationTests.swift
//
// Coverage for the zip-bomb guard added in issue #554.  Pure helper-level
// tests against real zips on disk — no HTTP plumbing needed.

import Foundation
import XCTVapor
import XCTest

@testable import chickadee_server

final class ZipUploadValidationTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-zipguard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// Builds a zip on disk with the given entries (name → content bytes).
    private func makeZip(named: String, entries: [(String, Data)]) throws -> String {
        let workDir = tmpDir.appendingPathComponent("work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        for (name, data) in entries {
            let fileURL = workDir.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL)
        }
        let zipPath = tmpDir.appendingPathComponent(named).path
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = workDir
        zip.arguments = ["-q", "-r", zipPath, "."]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0, "zip command must succeed")
        try FileManager.default.removeItem(at: workDir)
        return zipPath
    }

    // MARK: - Happy path

    func testValidateZipUploadSize_acceptsNormalZip() throws {
        let zipPath = try makeZip(
            named: "ok.zip",
            entries: [
                ("readme.txt", Data("hello world".utf8)),
                ("nested/a.py", Data("print('a')".utf8)),
            ])
        XCTAssertNoThrow(try validateZipUploadSize(zipPath: zipPath))
    }

    // MARK: - Per-entry limit

    func testValidateZipUploadSize_rejectsOversizedEntry() throws {
        // Tight per-entry limit; total stays well under.
        let limits = ZipUploadLimits(
            maxTotalUncompressedBytes: 10 * 1024 * 1024,
            maxEntryUncompressedBytes: 1024
        )
        let big = Data(repeating: 0x41, count: 5_000)
        let zipPath = try makeZip(named: "big-entry.zip", entries: [("big.bin", big)])

        XCTAssertThrowsError(try validateZipUploadSize(zipPath: zipPath, limits: limits)) { err in
            guard case ZipUploadValidationError.entrySizeExceeded(let name, _, _) = err else {
                XCTFail("Expected entrySizeExceeded, got \(err)")
                return
            }
            XCTAssertTrue(name.contains("big.bin"), "Reported name should identify the offending entry")
        }
    }

    // MARK: - Total limit

    func testValidateZipUploadSize_rejectsOversizedTotal() throws {
        // Per-entry generous; total tiny — every entry is under per-entry
        // but they sum past the total cap.
        let limits = ZipUploadLimits(
            maxTotalUncompressedBytes: 4_000,
            maxEntryUncompressedBytes: 10 * 1024 * 1024
        )
        let chunk = Data(repeating: 0x41, count: 2_000)
        let zipPath = try makeZip(
            named: "many.zip",
            entries: [
                ("a.bin", chunk),
                ("b.bin", chunk),
                ("c.bin", chunk),
            ])

        XCTAssertThrowsError(try validateZipUploadSize(zipPath: zipPath, limits: limits)) { err in
            guard case ZipUploadValidationError.totalSizeExceeded = err else {
                XCTFail("Expected totalSizeExceeded, got \(err)")
                return
            }
        }
    }

    // MARK: - Inspection failure

    func testValidateZipUploadSize_failsCleanlyOnCorruptZip() throws {
        let badPath = tmpDir.appendingPathComponent("not-a-zip.zip").path
        try Data("definitely not a zip".utf8).write(to: URL(fileURLWithPath: badPath))

        XCTAssertThrowsError(try validateZipUploadSize(zipPath: badPath)) { err in
            guard case ZipUploadValidationError.inspectionFailed = err else {
                XCTFail("Expected inspectionFailed for a corrupt zip, got \(err)")
                return
            }
        }
    }
}
