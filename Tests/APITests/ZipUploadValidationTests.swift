// Tests/APITests/ZipUploadValidationTests.swift
//
// Coverage for the zip-bomb guard added in issue #554.  Pure helper-level
// tests against real zips on disk — no HTTP plumbing needed.

import Foundation
import Testing
import XCTVapor

@testable import chickadee_server

@Suite final class ZipUploadValidationTests {

    private let tmpDir: URL

    init() throws {
        self.tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-zipguard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    deinit {
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
        #expect(zip.terminationStatus == 0, "zip command must succeed")
        try FileManager.default.removeItem(at: workDir)
        return zipPath
    }

    // MARK: - Happy path

    @Test func validateZipUploadSize_acceptsNormalZip() async throws {
        let zipPath = try makeZip(
            named: "ok.zip",
            entries: [
                ("readme.txt", Data("hello world".utf8)),
                ("nested/a.py", Data("print('a')".utf8)),
            ])
        try validateZipUploadSize(zipPath: zipPath)

    }

    // MARK: - Per-entry limit

    @Test func validateZipUploadSize_rejectsOversizedEntry() async throws {
        // Tight per-entry limit; total stays well under.
        let limits = ZipUploadLimits(
            maxTotalUncompressedBytes: 10 * 1024 * 1024,
            maxEntryUncompressedBytes: 1024
        )
        let big = Data(repeating: 0x41, count: 5_000)
        let zipPath = try makeZip(named: "big-entry.zip", entries: [("big.bin", big)])

        #expect { try validateZipUploadSize(zipPath: zipPath, limits: limits) } throws: { error in
            guard case ZipUploadValidationError.entrySizeExceeded(let name, _, _) = error else {
                Issue.record("Expected entrySizeExceeded, got \(error)")
                return false
            }
            #expect(name.contains("big.bin"), "Reported name should identify the offending entry")

            return true
        }

    }

    // MARK: - Total limit

    @Test func validateZipUploadSize_rejectsOversizedTotal() async throws {
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

        #expect { try validateZipUploadSize(zipPath: zipPath, limits: limits) } throws: { error in
            guard case ZipUploadValidationError.totalSizeExceeded = error else {
                Issue.record("Expected totalSizeExceeded, got \(error)")
                return false
            }

            return true
        }

    }

    // MARK: - Inspection failure

    @Test func validateZipUploadSize_failsCleanlyOnCorruptZip() async throws {
        let badPath = tmpDir.appendingPathComponent("not-a-zip.zip").path
        try Data("definitely not a zip".utf8).write(to: URL(fileURLWithPath: badPath))

        #expect { try validateZipUploadSize(zipPath: badPath) } throws: { error in
            guard case ZipUploadValidationError.inspectionFailed = error else {
                Issue.record("Expected inspectionFailed for a corrupt zip, got \(error)")
                return false
            }

            return true
        }

    }
}
