// Tests/APITests/Assignments/SupportFileNamesTests.swift
//
// Which entries of a setup zip are support files: every entry that is neither
// a graded suite script nor one of the two reserved notebook names. The
// `get_support_files` tool and the class-activity opponent picker both read
// this list. These tests need no database: the setup is built in memory.

import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(1))) struct SupportFileNamesTests {
    private func makeSetup(entries: [String], suiteScripts: [String]) async throws -> (APITestSetup, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("support-file-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let zipPath = directory.appendingPathComponent("setup.zip").path
        try await writeZipFixture(at: zipPath, entries: entries.map { ($0, "x\n") })
        let suites = suiteScripts.map { "{\"tier\":\"public\",\"script\":\"\($0)\"}" }.joined(separator: ",")
        let manifest = """
            {"schemaVersion":1,"requiredFiles":[],"testSuites":[\(suites)],"timeLimitSeconds":10,"makefile":null}
            """
        let setup = APITestSetup(id: "sfn_test", manifest: manifest, zipPath: zipPath, courseID: UUID())
        return (setup, directory)
    }

    @Test func suiteScriptsAndReservedNotebooksAreNotSupportFiles() async throws {
        let (setup, directory) = try await makeSetup(
            entries: ["test_a.sh", "test_b.sh", "assignment.ipynb", "solution.ipynb", "helper.py", "data.csv"],
            suiteScripts: ["test_a.sh", "test_b.sh"])
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(await currentSupportFileNames(setup: setup) == ["data.csv", "helper.py"])
    }

    @Test func aScriptThatNoSuiteNamesIsASupportFile() async throws {
        let (setup, directory) = try await makeSetup(
            entries: ["test_a.sh", "bot.sh"], suiteScripts: ["test_a.sh"])
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(await currentSupportFileNames(setup: setup) == ["bot.sh"])
    }

    @Test func aSetupWithOnlySuiteScriptsAndNotebooksHasNoSupportFiles() async throws {
        let (setup, directory) = try await makeSetup(
            entries: ["test_a.sh", "assignment.ipynb"], suiteScripts: ["test_a.sh"])
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(await currentSupportFileNames(setup: setup).isEmpty)
    }
}
