// Tests/APITests/Notebooks/NotebookBytesCacheMissTests.swift
//
// `NotebookBytesCache` remembers a setup whose zip holds no notebook, so the
// result-ingest path stops listing the zip on every result, and it keeps the
// contribution-slot count beside the bytes. A remembered miss must still give
// way to a zip that gains a notebook and to a different starter name, and it
// must throw the same error as an unremembered one.

import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) final class NotebookBytesCacheMissTests {

    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nbcache-miss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeZip(name: String, entries: [String: String]) async throws -> String {
        let sourceDir = tempDir.appendingPathComponent("\(name)-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        for (entryName, content) in entries {
            try content.write(to: sourceDir.appendingPathComponent(entryName), atomically: true, encoding: .utf8)
        }
        let zipPath = tempDir.appendingPathComponent("\(name).zip").path
        try await repackZipFromDirectory(zipPath: zipPath, sourceDir: sourceDir)
        return zipPath
    }

    private func zipSource(_ zipPath: String, starter: String? = nil) -> NotebookSourceRef {
        NotebookSourceRef(notebookPath: nil, zipPath: zipPath, starterNotebook: starter, setupID: "setup_miss")
    }

    /// The setup ID the lookup threw, or nil when it did not throw.
    private func thrownSetupID(_ cache: NotebookBytesCache, _ source: NotebookSourceRef) async -> String? {
        do {
            _ = try await cache.notebookData(for: source)
            return nil
        } catch {
            switch error {
            case .notFound(let setupID): return setupID
            }
        }
    }

    private static let notebookJSON = """
        {"cells":[{"cell_type":"code","source":["x = 1"],"metadata":{"chickadee_slot":"1"},"outputs":[],\
        "execution_count":null},{"cell_type":"code","source":["y = 2"],"metadata":{"chickadee_slot":"2"},\
        "outputs":[],"execution_count":null}],"metadata":{},"nbformat":4,"nbformat_minor":5}
        """

    @Test func aZipWithNoNotebookThrowsTheSameErrorEveryTime() async throws {
        let zipPath = try await writeZip(name: "no-notebook", entries: ["test_a.sh": "exit 0"])
        let cache = NotebookBytesCache()
        #expect(await thrownSetupID(cache, zipSource(zipPath)) == "setup_miss")
        #expect(await thrownSetupID(cache, zipSource(zipPath)) == "setup_miss")
        #expect(await cache.declaredContributionSlotCount(for: zipSource(zipPath)) == 0)
    }

    @Test func aZipThatGainsANotebookIsRead() async throws {
        let zipPath = try await writeZip(name: "gains", entries: ["test_a.sh": "exit 0"])
        let cache = NotebookBytesCache()
        #expect(await thrownSetupID(cache, zipSource(zipPath)) == "setup_miss")

        try await updateScriptInZip(zipPath: zipPath, filename: "assignment.ipynb", content: Self.notebookJSON)
        let data = try await cache.notebookData(for: zipSource(zipPath))
        #expect(String(data: data, encoding: .utf8)?.contains("x = 1") == true)
    }

    @Test func aRememberedMissDoesNotHideAnotherStarterName() async throws {
        let zipPath = try await writeZip(name: "starter-name", entries: ["starter.json": Self.notebookJSON])
        let cache = NotebookBytesCache()
        #expect(await thrownSetupID(cache, zipSource(zipPath)) == "setup_miss")

        let named = zipSource(zipPath, starter: "starter.json")
        #expect(await thrownSetupID(cache, named) == nil)
    }

    @Test func theSlotCountMatchesTheNotebookAndIsKept() async throws {
        let zipPath = try await writeZip(name: "slots", entries: ["assignment.ipynb": Self.notebookJSON])
        let cache = NotebookBytesCache()
        let data = try await cache.notebookData(for: zipSource(zipPath))
        let expected = NotebookContributionSlots.declaredSlotCount(inInstructorNotebook: data)
        #expect(expected == 2)
        #expect(await cache.declaredContributionSlotCount(for: zipSource(zipPath)) == expected)
        #expect(await cache.declaredContributionSlotCount(for: zipSource(zipPath)) == expected)
    }
}
