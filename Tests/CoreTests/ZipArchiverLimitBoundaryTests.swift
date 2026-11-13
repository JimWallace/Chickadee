// Tests/CoreTests/ZipArchiverLimitBoundaryTests.swift
//
// The zip-bomb limits (`ZipExtractionLimits`, #2898) at their boundaries: an
// archive that declares exactly the limit is extracted, and one entry or one
// byte over it is refused before anything is written.
//
// `ZipArchiver` is Core, but its only limit tests lived in APITests, which the
// mutation sweep skips. The 2026-11-10 sweep (#2970) found every comparison
// in `requireWithinExtractionLimits` surviving on that basis, so the invariant
// is pinned here, in the layer it belongs to.

import ChickadeeTestSupport
import Foundation
import Testing

@testable import Core

// `.serialized`: each test spawns zip and unzip, as `ZipArchiverTests` does.
@Suite(.serialized, .timeLimit(.minutes(2)))
final class ZipArchiverLimitBoundaryTests {

    private static let fileCount = 3
    private static let bytesEach = 100
    private static let totalBytes = fileCount * bytesEach

    private let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-zipboundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// A zip of `fileCount` files of `bytesEach` bytes, all at its root, so
    /// its directory declares exactly `fileCount` entries and `totalBytes`
    /// uncompressed bytes.
    private func makeZip() async throws -> String {
        let source = tmpDir.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for index in 0..<Self.fileCount {
            try Data(repeating: UInt8(ascii: "a"), count: Self.bytesEach)
                .write(to: source.appendingPathComponent("f\(index).txt"))
        }
        let zipPath = tmpDir.appendingPathComponent("\(UUID().uuidString).zip").path
        try await createZipArchive(sourceDir: source, outputPath: zipPath)
        return zipPath
    }

    private func extract(_ zipPath: String, bytes: Int, entries: Int) async throws -> URL {
        let dest = tmpDir.appendingPathComponent("dest-\(UUID().uuidString)")
        try await extractZipArchive(
            zipPath: zipPath, into: dest,
            limits: ZipExtractionLimits(maxTotalUncompressedBytes: bytes, maxEntryCount: entries))
        return dest
    }

    @Test func anArchiveExactlyAtBothLimitsIsExtracted() async throws {
        let zipPath = try await makeZip()
        let dest = try await extract(zipPath, bytes: Self.totalBytes, entries: Self.fileCount)
        for index in 0..<Self.fileCount {
            #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("f\(index).txt").path))
        }
    }

    @Test func anArchiveWellUnderBothLimitsIsExtracted() async throws {
        let zipPath = try await makeZip()
        let dest = try await extract(zipPath, bytes: Self.totalBytes * 10, entries: Self.fileCount * 10)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("f0.txt").path))
    }

    @Test func oneEntryOverTheLimitIsRefusedBeforeAnythingIsWritten() async throws {
        let zipPath = try await makeZip()
        let dest = tmpDir.appendingPathComponent("over-entries")
        let error = await #expect(throws: ZipArchiverError.self) {
            try await extractZipArchive(
                zipPath: zipPath, into: dest,
                limits: ZipExtractionLimits(
                    maxTotalUncompressedBytes: Self.totalBytes, maxEntryCount: Self.fileCount - 1))
        }
        guard case .extractionLimitExceeded(let reason) = error else {
            throw IssueRecorded("expected extractionLimitExceeded, got \(String(describing: error))")
        }
        #expect(reason.contains("entries"))
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func oneByteOverTheLimitIsRefusedBeforeAnythingIsWritten() async throws {
        let zipPath = try await makeZip()
        let dest = tmpDir.appendingPathComponent("over-bytes")
        let error = await #expect(throws: ZipArchiverError.self) {
            try await extractZipArchive(
                zipPath: zipPath, into: dest,
                limits: ZipExtractionLimits(
                    maxTotalUncompressedBytes: Self.totalBytes - 1, maxEntryCount: Self.fileCount))
        }
        guard case .extractionLimitExceeded(let reason) = error else {
            throw IssueRecorded("expected extractionLimitExceeded, got \(String(describing: error))")
        }
        #expect(reason.contains("bytes uncompressed"))
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }
}
