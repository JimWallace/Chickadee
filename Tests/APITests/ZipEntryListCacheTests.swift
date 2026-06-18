import Foundation
import Testing

@testable import APIServer

@Suite final class ZipEntryListCacheTests {

    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-entry-list-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Builds (or rebuilds) `name`.zip from the given entries and returns its path.
    private func writeZip(name: String, entries: [String: String]) throws -> String {
        let sourceDir = tempDir.appendingPathComponent("\(name)-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        for (entryName, content) in entries {
            try content.write(
                to: sourceDir.appendingPathComponent(entryName), atomically: true, encoding: .utf8)
        }
        let zipPath = tempDir.appendingPathComponent("\(name).zip").path
        try repackZipFromDirectory(zipPath: zipPath, sourceDir: sourceDir)
        return zipPath
    }

    @Test func entriesListsZipContentsAndCaches() async throws {
        let cache = ZipEntryListCache()
        let zipPath = try writeZip(
            name: "entries",
            entries: ["assignment.ipynb": "{}", "helper.py": "x = 1", "test_a.sh": "exit 0"]
        )
        let first = await cache.entries(zipPath: zipPath)
        #expect(Set(first) == ["assignment.ipynb", "helper.py", "test_a.sh"])
        // Second lookup is served from cache and must agree.
        #expect(await cache.entries(zipPath: zipPath) == first)
    }

    @Test func missingZipReturnsEmptyEntries() async throws {
        let cache = ZipEntryListCache()
        let zipPath = tempDir.appendingPathComponent("does-not-exist.zip").path
        #expect(await cache.entries(zipPath: zipPath).isEmpty)
    }

    @Test func zipWithNotebookReportsTrue() async throws {
        let cache = ZipEntryListCache()
        let zipPath = try writeZip(
            name: "with-notebook",
            entries: ["assignment.ipynb": "{}", "test_a.sh": "exit 0"]
        )
        #expect(await cache.zipContainsNotebook(zipPath: zipPath))
        // Second lookup is served from cache and must agree.
        #expect(await cache.zipContainsNotebook(zipPath: zipPath))
    }

    @Test func zipWithoutNotebookReportsFalse() async throws {
        let cache = ZipEntryListCache()
        let zipPath = try writeZip(name: "no-notebook", entries: ["test_a.sh": "exit 0"])
        #expect(await cache.zipContainsNotebook(zipPath: zipPath) == false)
    }

    @Test func missingZipReportsFalse() async throws {
        let cache = ZipEntryListCache()
        let zipPath = tempDir.appendingPathComponent("does-not-exist.zip").path
        #expect(await cache.zipContainsNotebook(zipPath: zipPath) == false)
    }

    @Test func rewritingZipInvalidatesCachedEntries() async throws {
        let cache = ZipEntryListCache()
        let zipPath = try writeZip(
            name: "mutating",
            entries: ["assignment.ipynb": "{}", "test_a.sh": "exit 0"]
        )
        #expect(await cache.zipContainsNotebook(zipPath: zipPath))

        // Rebuild the same zip path without a notebook — the mtime/size key
        // changes, so the cached list (and the derived `true`) must not be
        // returned.
        let replacement = try writeZip(name: "mutating-replacement", entries: ["test_a.sh": "exit 0"])
        try FileManager.default.removeItem(atPath: zipPath)
        try FileManager.default.copyItem(atPath: replacement, toPath: zipPath)
        #expect(await cache.entries(zipPath: zipPath) == ["test_a.sh"])
        #expect(await cache.zipContainsNotebook(zipPath: zipPath) == false)
    }
}
