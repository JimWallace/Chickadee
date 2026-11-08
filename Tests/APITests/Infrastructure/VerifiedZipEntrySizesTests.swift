// Tests/APITests/Infrastructure/VerifiedZipEntrySizesTests.swift
//
// `verifiedZipEntrySizes` answers `get_support_files` from the zip's
// directory. Every size it gives must be the byte count `extractZipEntry`
// returns, and a name it cannot answer for exactly must be left out, so the
// caller extracts it as before.

import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) final class VerifiedZipEntrySizesTests {

    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verified-zip-sizes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeZip(entries: [String: Data]) async throws -> String {
        let sourceDir = tempDir.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        for (entryName, content) in entries {
            try content.write(to: sourceDir.appendingPathComponent(entryName))
        }
        let zipPath = tempDir.appendingPathComponent("\(UUID().uuidString).zip").path
        try await repackZipFromDirectory(zipPath: zipPath, sourceDir: sourceDir)
        return zipPath
    }

    @Test func eachSizeIsTheExtractedByteCount() async throws {
        let entries: [String: Data] = [
            "data[1].csv": Data(String(repeating: "1,2,3\n", count: 500).utf8),
            "notes with space.txt": Data("hello".utf8),
            "empty.txt": Data(),
            "binary.bin": Data((0..<300).map { UInt8($0 % 256) }),
        ]
        let zipPath = try await writeZip(entries: entries)
        let names = Array(entries.keys)

        let sizes = await verifiedZipEntrySizes(zipPath: zipPath, entryNames: names)
        #expect(Set(sizes.keys) == Set(names))
        for name in names {
            let extracted = await extractZipEntry(zipPath: zipPath, entryName: name)
            #expect(sizes[name] == extracted?.count)
        }
    }

    @Test func aNameTheTableCannotShowExactlyIsLeftOut() async throws {
        // `unzip -v` columns are split on spaces, so a run of spaces in a name
        // does not survive the parse.
        let zipPath = try await writeZip(entries: [
            "two  spaces.txt": Data("x".utf8), "plain.txt": Data("yy".utf8),
        ])
        let sizes = await verifiedZipEntrySizes(zipPath: zipPath, entryNames: ["two  spaces.txt", "plain.txt"])
        #expect(sizes == ["plain.txt": 2])
    }

    @Test func aNameWithNoEntryLeavesEveryNameOut() async throws {
        let zipPath = try await writeZip(entries: ["plain.txt": Data("yy".utf8)])
        #expect(await verifiedZipEntrySizes(zipPath: zipPath, entryNames: ["plain.txt", "missing.txt"]).isEmpty)
    }
}
