// Tests/APITests/Admin/AdminDeploymentRoutesTests.swift
//
// The admin Deployment page and its four actions (docs/release-gate.md). The
// page asks and the deploy daemon decides, so each action is pinned by the
// request file it writes and the audit entry it records, and each refusal by
// writing nothing. The daemon's side (what it accepts) is tested in
// scripts/test-chickadee-deployer.sh.
//
// `DeployStateFolderTests` drives `DeployStateFolder` directly, with no
// database: the release-tag and release-notes parsing, and the file I/O in a
// temporary state folder (the history order and limit, a history line that
// does not parse, the count of waiting requests, and a request write that
// fails).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2)))
final class AdminDeploymentRoutesTests {

    let app: Application
    let stateDirectory: URL

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-deploy")
        stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deploy-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: stateDirectory.appendingPathComponent("requests"), withIntermediateDirectories: true)
        app.deployStateDirectory = stateDirectory.path
    }

    deinit {
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    private func writeStatus(
        held: String?, approved: String? = nil, paused: Bool = false, mode: String = "gated-minors",
        channel: String = "releases"
    )
        throws
    {
        let heldJSON = held.map { "\"\($0)\"" } ?? "null"
        let approvedJSON = approved.map { "\"\($0)\"" } ?? "null"
        let status = """
            {"state":"\(held == nil ? "idle" : "pending_approval")","deployedVersion":"0.5.980",\
            "latestSeen":"v0.6.0","detail":"release v0.6.0 needs approval","paused":\(paused),\
            "mode":"\(mode)","channel":"\(channel)","heldVersion":\(heldJSON),"approvedVersion":\(approvedJSON),\
            "updatedAt":"2026-11-20T10:00:00Z"}
            """
        try status.write(
            to: stateDirectory.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
    }

    /// The request files written so far, decoded.
    private func requests() throws -> [[String: String]] {
        let folder = stateDirectory.appendingPathComponent("requests")
        return try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .map { name in
                let data = try Data(contentsOf: folder.appendingPathComponent(name))
                return try JSONDecoder().decode([String: String].self, from: data)
            }
    }

    private func post(
        _ path: String, fields: [String: String] = [:], cookie: String
    ) async throws -> (status: HTTPStatus, location: String?) {
        let (token, bound) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var status: HTTPStatus = .ok
        var location: String?
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: bound)
                try req.content.encode(fields.merging(["_csrf": token]) { $1 }, as: .urlEncodedForm)
            },
            afterResponse: { res in
                status = res.status
                location = res.headers.first(name: .location)
            })
        return (status, location)
    }

    private func auditActions() async throws -> [String] {
        try await APIAuditLogEntry.query(on: app.db).all().map(\.action)
    }

    // MARK: - The page

    @Test func thePageShowsTheHeldReleaseItsContractChangeAndTheModes() async throws {
        try await withApp(app) { app in
            try writeStatus(held: "v0.6.0")
            let notes = """
                {"deployedVersion":"0.5.980","heldVersion":"v0.6.0",\
                "releases":[{"tag":"v0.6.0","name":"Chickadee v0.6.0","body":"- **Kernels.** Re-vendored (#3100).\\n- A fix (#3099)."}],\
                "minorReleasePullRequests":[{"number":3100,"title":"Re-vendor the xeus kernels"}]}
                """
            try notes.write(
                to: stateDirectory.appendingPathComponent("pending-notes.json"), atomically: true, encoding: .utf8)
            let cookie = try await loginAsAdmin("deploy_admin_page", on: app)
            let html = try await getHTML("/admin/deployment", cookie: cookie, on: app)
            #expect(html.contains("Waiting for approval"))
            #expect(html.contains("action=\"/admin/deployment/approve\""))
            #expect(html.contains("Contract change"))
            #expect(html.contains("Kernels. Re-vendored (#3100)."))
            #expect(html.contains("action=\"/admin/deployment/mode\""))
            #expect(html.contains("action=\"/admin/deployment/pause\""))
            #expect(!html.contains("/admin/deployment/rollback"))
        }
    }

    @Test func aNonAdminCannotSeeThePageOrSendARequest() async throws {
        try await withApp(app) { app in
            try writeStatus(held: "v0.6.0")
            let cookie = try await loginUser(username: "deploy_plain", password: "pw", role: "user", on: app)
            let response = try await getResponse("/admin/deployment", cookie: cookie, on: app)
            #expect(response.status != .ok)
            _ = try await post("/admin/deployment/approve", fields: ["version": "v0.6.0"], cookie: cookie)
            _ = try await post("/admin/deployment/pause", cookie: cookie)
            #expect(try requests().isEmpty)
        }
    }

    @Test func thePageShowsTheChannelReadOnly() async throws {
        try await withApp(app) { app in
            try writeStatus(held: "v0.7.0-rc.2", mode: "autonomous", channel: "prereleases")
            let cookie = try await loginAsAdmin("deploy_admin_channel", on: app)
            let html = try await getHTML("/admin/deployment", cookie: cookie, on: app)
            #expect(html.contains("<code>prereleases</code>"))
            #expect(!html.contains("name=\"channel\""))
            let result = try await post(
                "/admin/deployment/approve", fields: ["version": "v0.7.0-rc.2"], cookie: cookie)
            #expect(result.location == "/admin/deployment?notice=approved")
            #expect(try requests().first?["version"] == "v0.7.0-rc.2")
        }
    }

    // MARK: - The admin MCP status

    @Test func getDeployStatusReportsTheModeAndTheHeldRelease() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "deploy-mcp-admin", role: "admin")
            try writeStatus(held: "v0.6.0", approved: "v0.6.0", mode: "manual")
            let context = adminMCPContext(app, subject: "deploy-mcp-admin")
            let output = try await GetDeployStatusTool().execute(.init(), context)
            #expect(output.mode == "manual")
            #expect(output.heldVersion == "v0.6.0")
            #expect(output.approvedVersion == "v0.6.0")
            #expect(output.channel == "releases")
        }
    }

    // MARK: - Approve

    @Test func approvingTheHeldVersionWritesOneRequestAndOneAuditEntry() async throws {
        try await withApp(app) { app in
            try writeStatus(held: "v0.6.0")
            let cookie = try await loginAsAdmin("deploy_admin_approve", on: app)
            let result = try await post("/admin/deployment/approve", fields: ["version": " v0.6.0 "], cookie: cookie)
            #expect(result.location == "/admin/deployment?notice=approved")
            let written = try requests()
            #expect(written.count == 1)
            #expect(written.first?["request"] == "approve")
            #expect(written.first?["version"] == "v0.6.0")
            #expect(written.first?["user"] == "deploy_admin_approve")
            #expect(try await auditActions().contains(AuditAction.deployApproveRequested.rawValue))
        }
    }

    @Test func approvingAnotherVersionWritesNothing() async throws {
        try await withApp(app) { app in
            try writeStatus(held: "v0.6.0")
            let cookie = try await loginAsAdmin("deploy_admin_mismatch", on: app)
            let result = try await post("/admin/deployment/approve", fields: ["version": "v0.5.990"], cookie: cookie)
            #expect(result.location == "/admin/deployment?notice=versionMismatch")
            #expect(try requests().isEmpty)
            #expect(try await !auditActions().contains(AuditAction.deployApproveRequested.rawValue))
        }
    }

    @Test func approvingWithNothingHeldWritesNothing() async throws {
        try await withApp(app) { app in
            try writeStatus(held: nil)
            let cookie = try await loginAsAdmin("deploy_admin_nothing", on: app)
            let result = try await post("/admin/deployment/approve", fields: ["version": "v0.6.0"], cookie: cookie)
            #expect(result.location == "/admin/deployment?notice=nothingHeld")
            #expect(try requests().isEmpty)
        }
    }

    // MARK: - Mode, pause, resume

    @Test func aModeChangeIsSentInBothDirections() async throws {
        try await withApp(app) { app in
            try writeStatus(held: nil)
            let cookie = try await loginAsAdmin("deploy_admin_mode", on: app)
            _ = try await post("/admin/deployment/mode", fields: ["mode": "autonomous"], cookie: cookie)
            _ = try await post("/admin/deployment/mode", fields: ["mode": "manual"], cookie: cookie)
            let bogus = try await post("/admin/deployment/mode", fields: ["mode": "yolo"], cookie: cookie)
            #expect(bogus.location == "/admin/deployment?notice=unknownMode")
            let modes = try requests().compactMap { $0["mode"] }
            #expect(Set(modes) == ["autonomous", "manual"])
            #expect(try await auditActions().filter { $0 == AuditAction.deployModeRequested.rawValue }.count == 2)
        }
    }

    @Test func pauseAndResumeAreSent() async throws {
        try await withApp(app) { app in
            try writeStatus(held: nil)
            let cookie = try await loginAsAdmin("deploy_admin_pause", on: app)
            _ = try await post("/admin/deployment/pause", cookie: cookie)
            _ = try await post("/admin/deployment/resume", cookie: cookie)
            let kinds = try requests().compactMap { $0["request"] }
            #expect(Set(kinds) == ["pause", "resume"])
            let actions = try await auditActions()
            #expect(actions.contains(AuditAction.deployPauseRequested.rawValue))
            #expect(actions.contains(AuditAction.deployResumeRequested.rawValue))
        }
    }

    @Test func withoutTheRequestsMountNothingIsSent() async throws {
        try await withApp(app) { app in
            try writeStatus(held: nil)
            try FileManager.default.removeItem(at: stateDirectory.appendingPathComponent("requests"))
            let cookie = try await loginAsAdmin("deploy_admin_nomount", on: app)
            let result = try await post("/admin/deployment/pause", cookie: cookie)
            #expect(result.location == "/admin/deployment?notice=requestsFolderMissing")
            #expect(try await !auditActions().contains(AuditAction.deployPauseRequested.rawValue))
            let html = try await getHTML("/admin/deployment", cookie: cookie, on: app)
            #expect(html.contains("The requests folder is not mounted"))
            #expect(!html.contains("action=\"/admin/deployment/pause\""))
        }
    }
}

@Suite struct DeployStateFolderTests {
    @Test func releaseNotesFlagTheEntriesThatNameAContractPullRequest() {
        let body = "### Changed\n\n- **Kernels.** Re-vendored\n  for R (#3100).\n- A fix (#3099).\n"
        let entries = DeployReleaseNotes.entries(in: body, contractPullRequests: [3100])
        #expect(entries.map(\.text) == ["Changed", "Kernels. Re-vendored for R (#3100).", "A fix (#3099)."])
        #expect(entries.map(\.isHeading) == [true, false, false])
        #expect(entries.map(\.isContractChange) == [false, true, false])
    }

    @Test func onlyTagsOfTheFormTheDaemonAcceptsAreReleaseTags() {
        #expect(DeployStateFolder.isReleaseTag("v0.6.0"))
        #expect(!DeployStateFolder.isReleaseTag("0.6.0"))
        #expect(!DeployStateFolder.isReleaseTag("v0.6"))
        #expect(!DeployStateFolder.isReleaseTag("v0.6.0; rm"))
        #expect(DeployStateFolder.isReleaseTag("v0.7.0-rc.12"))
        #expect(!DeployStateFolder.isReleaseTag("v0.7.0-rc"))
        #expect(!DeployStateFolder.isReleaseTag("v0.7.0-beta.1"))
    }

    @Test func notesForAnotherReleaseAreNotShown() {
        let notes = DeployPendingNotes(
            deployedVersion: "0.5.980", heldVersion: "v0.6.0", releases: [], minorReleasePullRequests: [])
        let held = AdminDeploymentView.makeHeld(version: "v0.6.1", approved: false, notes: notes)
        #expect(!held.hasNotes)
    }

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
