// Tests/APITests/Infrastructure/ZipExtractionLimitsTests.swift
//
// A student's submission zip is extracted on the runner, outside the
// sandbox's disk limit. A small deflated archive can expand about 1000:1, so
// `extractZipArchive(limits:)` refuses an archive whose directory declares
// more than the limits before anything is written (#2898).

import Foundation
import Testing

@testable import Core

// `.serialized`: each test spawns zip and unzip, as `ZipArchiverTests` does.
@Suite(.serialized, .timeLimit(.minutes(2)))
final class ZipExtractionLimitsTests {

    private let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-ziplimits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// A zip of `fileCount` files of `bytesEach` zero bytes: tiny on disk,
    /// large when extracted.
    private func makeZip(fileCount: Int, bytesEach: Int) async throws -> String {
        let source = tmpDir.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for index in 0..<fileCount {
            try Data(count: bytesEach).write(to: source.appendingPathComponent("f\(index).bin"))
        }
        let zipPath = tmpDir.appendingPathComponent("\(UUID().uuidString).zip").path
        try await createZipArchive(sourceDir: source, outputPath: zipPath)
        return zipPath
    }

    @Test func anArchiveWithinTheLimitsIsExtracted() async throws {
        let zipPath = try await makeZip(fileCount: 2, bytesEach: 1_000)
        let dest = tmpDir.appendingPathComponent("ok")
        try await extractZipArchive(
            zipPath: zipPath, into: dest,
            limits: ZipExtractionLimits(maxTotalUncompressedBytes: 10_000, maxEntryCount: 10))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("f1.bin").path))
    }

    @Test func anArchiveThatExpandsPastTheByteLimitIsRefused() async throws {
        let zipPath = try await makeZip(fileCount: 1, bytesEach: 3_000_000)
        let dest = tmpDir.appendingPathComponent("bomb")
        await #expect(throws: ZipArchiverError.self) {
            try await extractZipArchive(
                zipPath: zipPath, into: dest,
                limits: ZipExtractionLimits(maxTotalUncompressedBytes: 1_000_000, maxEntryCount: 10))
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func anArchiveWithTooManyEntriesIsRefused() async throws {
        let zipPath = try await makeZip(fileCount: 5, bytesEach: 1)
        let dest = tmpDir.appendingPathComponent("many")
        await #expect(throws: ZipArchiverError.self) {
            try await extractZipArchive(
                zipPath: zipPath, into: dest,
                limits: ZipExtractionLimits(maxTotalUncompressedBytes: 1_000_000, maxEntryCount: 4))
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func aFileThatIsNotAZipIsRefusedUnderLimits() async throws {
        let notZip = tmpDir.appendingPathComponent("not.zip")
        try Data("plain text".utf8).write(to: notZip)
        await #expect(throws: ZipArchiverError.self) {
            try await extractZipArchive(
                zipPath: notZip.path, into: tmpDir.appendingPathComponent("x"), limits: .submission)
        }
    }

    @Test(arguments: [
        ("2 files, 3000003 bytes uncompressed, 2926 bytes compressed:  99.9%", 2, 3_000_003),
        ("1 file, 1 byte uncompressed, 3 bytes compressed:  -200.0%", 1, 1),
    ])
    func theDirectoryTotalsAreParsed(line: String, entries: Int, bytes: Int) throws {
        let totals = try #require(zipDirectoryTotals(line))
        #expect(totals.entries == entries)
        #expect(totals.uncompressedBytes == bytes)
    }

    @Test func aLineWithoutTotalsParsesToNil() {
        #expect(zipDirectoryTotals("End-of-central-directory signature not found.") == nil)
    }
}
