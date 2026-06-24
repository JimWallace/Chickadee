// Tests/APITests/GraderOnlyEnforcementTests.swift
//
// Grader-only files (option B — docs/datasets.md) must be withheld from every
// student-facing path while the canonical stored zip (which the native worker
// downloads) keeps them. The student-facing test-setup download serves a
// filtered copy via `filteredZipCopy`; these tests pin that helper's contract
// directly (it's the security-critical new logic):
//   - the excluded entry is gone, every other entry + its bytes survive,
//   - the SOURCE zip is left untouched (so the worker still gets the file),
//   - excluding nothing yields a faithful copy.
// The name-union exclusions at the other delivery points (editor symlink,
// support-file download, MCP listing) reuse the existing reservedNames pattern.

import Foundation
import Testing

@testable import APIServer

@Suite struct GraderOnlyFilteredZipTests {

    /// Packs `files` (name → content) into a fresh zip and returns its path.
    private func makeZip(_ files: [String: String]) throws -> String {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("go-src-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let zipPath = fm.temporaryDirectory.appendingPathComponent("go-\(UUID().uuidString).zip").path
        try repackZipFromDirectory(zipPath: zipPath, sourceDir: dir)
        return zipPath
    }

    @Test func excludesGraderOnlyButKeepsOthersWithContent() throws {
        let zip = try makeZip(["a.py": "print(1)", "data.csv": "id\n1\n", "test.csv": "ans\n42\n"])
        let filtered = try filteredZipCopy(sourceZip: zip, excluding: ["test.csv"])
        defer { try? FileManager.default.removeItem(at: filtered.deletingLastPathComponent()) }

        let entries = Set(listZipEntries(zipPath: filtered.path))
        #expect(!entries.contains("test.csv"), "grader-only file must be removed")
        #expect(entries == ["a.py", "data.csv"])
        let kept = try #require(extractZipEntry(zipPath: filtered.path, entryName: "data.csv"))
        #expect(String(data: kept, encoding: .utf8) == "id\n1\n")
    }

    @Test func sourceZipIsLeftUntouched() throws {
        let zip = try makeZip(["a.py": "x", "test.csv": "secret"])
        let filtered = try filteredZipCopy(sourceZip: zip, excluding: ["test.csv"])
        defer { try? FileManager.default.removeItem(at: filtered.deletingLastPathComponent()) }
        // The worker still downloads the canonical stored zip — it must keep the file.
        #expect(Set(listZipEntries(zipPath: zip)) == ["a.py", "test.csv"])
    }

    @Test func excludingNothingIsAFaithfulCopy() throws {
        let zip = try makeZip(["a.py": "x", "data.csv": "y"])
        let filtered = try filteredZipCopy(sourceZip: zip, excluding: [])
        defer { try? FileManager.default.removeItem(at: filtered.deletingLastPathComponent()) }
        #expect(Set(listZipEntries(zipPath: filtered.path)) == ["a.py", "data.csv"])
    }
}
