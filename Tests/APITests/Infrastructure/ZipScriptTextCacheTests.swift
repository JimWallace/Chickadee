// Tests/APITests/Infrastructure/ZipScriptTextCacheTests.swift
//
// The script-text cache must return exactly what a loop over
// `readScriptFromZip` returns, and must never serve a text from an earlier
// state of the zip, even when a rewrite keeps the modification date.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) final class ZipScriptTextCacheTests {

    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-script-text-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Builds `name`.zip from `entries` (name to bytes) and returns its path.
    private func writeZip(name: String, entries: [String: Data]) async throws -> String {
        let sourceDir = tempDir.appendingPathComponent("\(name)-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        for (entryName, content) in entries {
            try content.write(to: sourceDir.appendingPathComponent(entryName))
        }
        let zipPath = tempDir.appendingPathComponent("\(name).zip").path
        try await repackZipFromDirectory(zipPath: zipPath, sourceDir: sourceDir)
        return zipPath
    }

    /// What the cache replaces: one `readScriptFromZip` per name.
    private func readOneByOne(zipPath: String, filenames: [String]) async -> [String: String] {
        var texts: [String: String] = [:]
        for name in filenames {
            texts[name] = await readScriptFromZip(zipPath: zipPath, filename: name)
        }
        return texts
    }

    @Test func returnsWhatReadScriptFromZipReturns() async throws {
        let zipPath = try await writeZip(
            name: "suite",
            entries: [
                "test_a.sh": Data("exit 0\n".utf8),
                "test_b.py": Data("print('b')\n".utf8),
                "data[1].csv": Data("x,y\n1,2\n".utf8),
                "binary.bin": Data([0xFF, 0xFE, 0x00, 0x80]),
            ])
        let names = ["test_a.sh", "test_b.py", "data[1].csv", "binary.bin", "missing.sh"]
        let expected = await readOneByOne(zipPath: zipPath, filenames: names)
        let cache = ZipScriptTextCache()

        #expect(await cache.texts(zipPath: zipPath, filenames: names) == expected)
        // The second read is served from the cache and must agree.
        #expect(await cache.texts(zipPath: zipPath, filenames: names) == expected)
        // A subset asks for only what it names.
        #expect(await cache.texts(zipPath: zipPath, filenames: ["test_a.sh"]) == ["test_a.sh": "exit 0\n"])
    }

    @Test func aRewriteIsSeenEvenWhenTheModificationDateIsKept() async throws {
        let zipPath = try await writeZip(name: "rewrite", entries: ["test_a.sh": Data("echo 1\n".utf8)])
        let pinned = Date(timeIntervalSince1970: 1_750_000_000)
        try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: zipPath)
        let cache = ZipScriptTextCache()
        #expect(await cache.texts(zipPath: zipPath, filenames: ["test_a.sh"]) == ["test_a.sh": "echo 1\n"])

        // The same length of text, then the old modification date put back:
        // a stat alone would call this the same zip.
        try await updateScriptInZip(zipPath: zipPath, filename: "test_a.sh", content: "echo 2\n")
        try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: zipPath)
        #expect(await cache.texts(zipPath: zipPath, filenames: ["test_a.sh"]) == ["test_a.sh": "echo 2\n"])
    }

    @Test func aMissingEntryThatAppearsLaterIsRead() async throws {
        let zipPath = try await writeZip(name: "appears", entries: ["test_a.sh": Data("exit 0\n".utf8)])
        let cache = ZipScriptTextCache()
        #expect(await cache.texts(zipPath: zipPath, filenames: ["test_b.sh"]).isEmpty)

        try await updateScriptInZip(zipPath: zipPath, filename: "test_b.sh", content: "exit 1\n")
        #expect(await cache.texts(zipPath: zipPath, filenames: ["test_b.sh"]) == ["test_b.sh": "exit 1\n"])
    }

    @Test func aSymlinkEntryGivesItsLinkText() async throws {
        let sourceDir = tempDir.appendingPathComponent("links-src")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: sourceDir.appendingPathComponent("link.sh").path, withDestinationPath: "/etc/hostname")
        let zipPath = tempDir.appendingPathComponent("links.zip").path
        try await runZipProcessExpectingSuccess(
            executablePath: "/usr/bin/zip", arguments: ["-q", "-y", "-r", zipPath, "."],
            workingDirectory: sourceDir)

        let expected = await readOneByOne(zipPath: zipPath, filenames: ["link.sh"])
        #expect(expected == ["link.sh": "/etc/hostname"])
        #expect(await ZipScriptTextCache().texts(zipPath: zipPath, filenames: ["link.sh"]) == expected)
    }

    @Test func aMissingZipGivesNoTexts() async throws {
        let zipPath = tempDir.appendingPathComponent("absent.zip").path
        #expect(await ZipScriptTextCache().texts(zipPath: zipPath, filenames: ["test_a.sh"]).isEmpty)
    }

    @Test func concurrentRequestsAllGetTheTexts() async throws {
        let entries = Dictionary(
            uniqueKeysWithValues: (1...12).map { ("test_\($0).sh", Data("exit \($0 % 2)\n".utf8)) })
        let zipPath = try await writeZip(name: "burst", entries: entries)
        let names = Array(entries.keys)
        let expected = await readOneByOne(zipPath: zipPath, filenames: names)
        let cache = ZipScriptTextCache()

        let results = await withTaskGroup(of: [String: String].self, returning: [[String: String]].self) { group in
            for _ in 0..<20 {
                group.addTask { await cache.texts(zipPath: zipPath, filenames: names) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 20)
        #expect(results.allSatisfy { $0 == expected })
    }
}
