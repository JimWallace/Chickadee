// Tests/APITests/Admin/DeployStateFolderFileTests.swift
//
// `DeployStateFolder` reads the deploy daemon's state folder and writes one
// request file at a time. The route tests reach it through the admin page,
// which needs a database; this suite drives the file I/O directly in a
// temporary folder: the history order and limit, a history line that does not
// parse, the count of waiting requests, and a request write that fails.

import Foundation
import Testing

@testable import APIServer

@Suite struct DeployStateFolderFileTests {

    /// A temporary state folder. The caller removes it.
    private static func makeStateFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deploy-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeHistory(_ lines: [String], to folder: URL) throws {
        try lines.joined(separator: "\n").write(
            to: folder.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8)
    }

    // MARK: - history(limit:)

    @Test func historyIsNewestFirstAndKeepsTheLastLimitLines() throws {
        let folder = try Self.makeStateFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.writeHistory(
            [
                #"{"version":"v0.6.1","action":"deploy"}"#,
                #"{"version":"v0.6.2","action":"deploy"}"#,
                #"{"version":"v0.6.3","action":"deploy"}"#,
            ], to: folder)
        let state = DeployStateFolder(directory: folder.path)

        #expect(state.history(limit: 2).map(\.version) == ["v0.6.3", "v0.6.2"])
        #expect(state.history(limit: 10).map(\.version) == ["v0.6.3", "v0.6.2", "v0.6.1"])
    }

    @Test func aHistoryLineThatDoesNotParseIsSkipped() throws {
        let folder = try Self.makeStateFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.writeHistory(
            [
                #"{"version":"v0.6.1","action":"deploy","user":"admin"}"#,
                "not json at all",
                "",
                #"{"version":"v0.6.2","action":"rollback","result":"ok"}"#,
            ], to: folder)
        let records = DeployStateFolder(directory: folder.path).history(limit: 10)

        #expect(records.map(\.version) == ["v0.6.2", "v0.6.1"])
        #expect(records.first?.action == "rollback")
        #expect(records.first?.result == "ok")
        #expect(records.last?.user == "admin")
    }

    /// A negative limit is treated as zero, not as "from the end".
    @Test func aZeroOrNegativeLimitGivesNoRecords() throws {
        let folder = try Self.makeStateFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.writeHistory([#"{"version":"v0.6.1"}"#], to: folder)
        let state = DeployStateFolder(directory: folder.path)

        #expect(state.history(limit: 0).isEmpty)
        #expect(state.history(limit: -3).isEmpty)
    }

    @Test func aMissingStateFolderReadsAsEmpty() {
        let state = DeployStateFolder(directory: "/nonexistent-\(UUID().uuidString)")
        #expect(state.history(limit: 5).isEmpty)
        #expect(state.status() == nil)
        #expect(state.pendingNotes() == nil)
        #expect(state.waitingRequestCount() == 0)
    }

    // MARK: - Requests

    @Test func aWrittenRequestIsCountedAndATemporaryFileIsNot() throws {
        let folder = try Self.makeStateFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = DeployStateFolder(directory: folder.path)
        try FileManager.default.createDirectory(at: state.requestsFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: state.requestsFolder.appendingPathComponent("partial.json.tmp"))

        let name = try state.write(.pause, user: "admin", at: Date(timeIntervalSince1970: 1_000))

        #expect(name.hasPrefix("1000000-"))
        #expect(name.hasSuffix(".json"))
        #expect(state.waitingRequestCount() == 1)
        let data = try Data(contentsOf: state.requestsFolder.appendingPathComponent(name))
        let body = try JSONDecoder().decode([String: String].self, from: data)
        #expect(body["request"] == "pause")
        #expect(body["user"] == "admin")
    }

    @Test func aWriteWithoutARequestsFolderIsRefused() throws {
        let folder = try Self.makeStateFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = DeployStateFolder(directory: folder.path)

        #expect(throws: DeployRequestWriteError.requestsFolderMissing) {
            try state.write(.resume, user: "admin")
        }
    }

    /// A `requests` entry that is a file, not a folder, passes the existence
    /// check. The write under it then fails.
    @Test func aWriteThatFailsReportsWriteFailed() throws {
        let folder = try Self.makeStateFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = DeployStateFolder(directory: folder.path)
        try Data("not a folder".utf8).write(to: state.requestsFolder)

        #expect(throws: DeployRequestWriteError.writeFailed) {
            try state.write(.approve(version: "v0.6.4"), user: "admin")
        }
    }
}
