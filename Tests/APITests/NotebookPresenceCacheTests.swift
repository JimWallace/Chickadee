import Foundation
import Testing

@testable import APIServer

@Suite final class NotebookPresenceCacheTests {

    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notebook-presence-cache-\(UUID().uuidString)")
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

    @Test func zipWithNotebookReportsTrue() async throws {
        let cache = NotebookPresenceCache()
        let zipPath = try writeZip(
            name: "with-notebook",
            entries: ["assignment.ipynb": "{}", "test_a.sh": "exit 0"]
        )
        #expect(await cache.zipContainsNotebook(zipPath: zipPath))
        // Second lookup is served from cache and must agree.
        #expect(await cache.zipContainsNotebook(zipPath: zipPath))
    }

    @Test func zipWithoutNotebookReportsFalse() async throws {
        let cache = NotebookPresenceCache()
        let zipPath = try writeZip(name: "no-notebook", entries: ["test_a.sh": "exit 0"])
        #expect(await cache.zipContainsNotebook(zipPath: zipPath) == false)
    }

    @Test func missingZipReportsFalse() async throws {
        let cache = NotebookPresenceCache()
        let zipPath = tempDir.appendingPathComponent("does-not-exist.zip").path
        #expect(await cache.zipContainsNotebook(zipPath: zipPath) == false)
    }

    @Test func rewritingZipInvalidatesCachedAnswer() async throws {
        let cache = NotebookPresenceCache()
        let zipPath = try writeZip(
            name: "mutating",
            entries: ["assignment.ipynb": "{}", "test_a.sh": "exit 0"]
        )
        #expect(await cache.zipContainsNotebook(zipPath: zipPath))

        // Rebuild the same zip path without a notebook — the mtime/size key
        // changes, so the cached `true` must not be returned.
        let replacement = try writeZip(name: "mutating-replacement", entries: ["test_a.sh": "exit 0"])
        try FileManager.default.removeItem(atPath: zipPath)
        try FileManager.default.copyItem(atPath: replacement, toPath: zipPath)
        #expect(await cache.zipContainsNotebook(zipPath: zipPath) == false)
    }
}
