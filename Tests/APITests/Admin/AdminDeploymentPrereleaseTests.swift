// Tests/APITests/Admin/AdminDeploymentPrereleaseTests.swift
//
// The Coming next card (docs/release-gate.md, "Approving a pre-release on
// production"). On the releases channel the daemon offers the newest
// pre-release in status.json (`prereleaseVersion`) with its notes in
// prerelease-notes.json. The page shows it with an approval form, the
// approve route accepts that exact version, and get_deploy_status reports it.
// No mode deploys a pre-release: the daemon side of that is in
// scripts/test-chickadee-deployer.sh.

import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2)))
final class AdminDeploymentPrereleaseTests {

    let app: Application
    let stateDirectory: URL

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-deploy-rc")
        stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deploy-state-rc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: stateDirectory.appendingPathComponent("requests"), withIntermediateDirectories: true)
        app.deployStateDirectory = stateDirectory.path
    }

    deinit {
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    /// Production up to date on 0.5.988, offering `prerelease`, optionally
    /// holding `held`.
    private func writeStatus(prerelease: String?, held: String? = nil, approved: String? = nil) throws {
        func json(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
        let status = """
            {"state":"\(held == nil ? "idle" : "pending_approval")","deployedVersion":"0.5.988",\
            "latestSeen":"v0.5.988","detail":"up to date (0.5.988)","paused":false,"mode":"gated-minors",\
            "channel":"releases","heldVersion":\(json(held)),"approvedVersion":\(json(approved)),\
            "prereleaseVersion":\(json(prerelease)),"updatedAt":"2026-11-20T10:00:00Z"}
            """
        try status.write(
            to: stateDirectory.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
    }

    private func writePrereleaseNotes(_ version: String) throws {
        let notes = """
            {"deployedVersion":"0.5.988","heldVersion":"\(version)",\
            "releases":[{"tag":"\(version)","name":"Chickadee \(version)",\
            "body":"### Removed\\n\\n- **The runner flag.** Removed (#3106)."}],\
            "minorReleasePullRequests":[{"number":3106,"title":"Remove the runner flag"}]}
            """
        try notes.write(
            to: stateDirectory.appendingPathComponent("prerelease-notes.json"), atomically: true, encoding: .utf8)
    }

    private func requests() throws -> [[String: String]] {
        let folder = stateDirectory.appendingPathComponent("requests")
        return try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".json") }
            .map {
                try JSONDecoder().decode(
                    [String: String].self, from: Data(contentsOf: folder.appendingPathComponent($0)))
            }
    }

    private func post(_ path: String, fields: [String: String], cookie: String) async throws -> String? {
        let (token, bound) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var location: String?
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: bound)
                try req.content.encode(fields.merging(["_csrf": token]) { $1 }, as: .urlEncodedForm)
            },
            afterResponse: { res in location = res.headers.first(name: .location) })
        return location
    }

    @Test func thePageOffersThePrereleaseWithItsNotesAndAnApprovalForm() async throws {
        try await withApp(app) { app in
            try writeStatus(prerelease: "v0.6.0-rc.11")
            try writePrereleaseNotes("v0.6.0-rc.11")
            let cookie = try await loginAsAdmin("deploy_rc_page", on: app)
            let html = try await getHTML("/admin/deployment", cookie: cookie, on: app)
            #expect(html.contains("Coming next"))
            #expect(html.contains("<code>v0.6.0-rc.11</code>"))
            #expect(html.contains("Approve v0.6.0-rc.11"))
            #expect(html.contains("deploys here only when approved"))
            #expect(html.contains("Remove the runner flag"))
            #expect(!html.contains("Waiting for approval"))
        }
    }

    @Test func withNoPrereleaseOfferedThereIsNoCard() async throws {
        try await withApp(app) { app in
            try writeStatus(prerelease: nil)
            let cookie = try await loginAsAdmin("deploy_rc_none", on: app)
            let html = try await getHTML("/admin/deployment", cookie: cookie, on: app)
            #expect(!html.contains("Coming next"))
        }
    }

    @Test func approvingTheOfferedPrereleaseWritesOneRequest() async throws {
        try await withApp(app) { app in
            try writeStatus(prerelease: "v0.6.0-rc.11")
            let cookie = try await loginAsAdmin("deploy_rc_approve", on: app)
            let location = try await post(
                "/admin/deployment/approve", fields: ["version": "v0.6.0-rc.11"], cookie: cookie)
            #expect(location == "/admin/deployment?notice=approved")
            let written = try requests()
            #expect(written.count == 1)
            #expect(written.first?["request"] == "approve")
            #expect(written.first?["version"] == "v0.6.0-rc.11")
        }
    }

    @Test func approvingAnOlderPrereleaseThanTheOfferedOneWritesNothing() async throws {
        try await withApp(app) { app in
            try writeStatus(prerelease: "v0.6.0-rc.11")
            let cookie = try await loginAsAdmin("deploy_rc_older", on: app)
            let location = try await post(
                "/admin/deployment/approve", fields: ["version": "v0.6.0-rc.10"], cookie: cookie)
            #expect(location == "/admin/deployment?notice=versionMismatch")
            #expect(try requests().isEmpty)
        }
    }

    @Test func theHeldReleaseAndTheOfferedPrereleaseCanEachBeApproved() async throws {
        try await withApp(app) { app in
            try writeStatus(prerelease: "v0.7.0-rc.1", held: "v0.6.1")
            let cookie = try await loginAsAdmin("deploy_rc_both", on: app)
            let html = try await getHTML("/admin/deployment", cookie: cookie, on: app)
            #expect(html.contains("Waiting for approval"))
            #expect(html.contains("Coming next"))
            #expect(html.contains("id=\"deploy-approve-version\""))
            #expect(html.contains("id=\"deploy-approve-prerelease\""))
            _ = try await post("/admin/deployment/approve", fields: ["version": "v0.6.1"], cookie: cookie)
            _ = try await post("/admin/deployment/approve", fields: ["version": "v0.7.0-rc.1"], cookie: cookie)
            #expect(Set(try requests().compactMap { $0["version"] }) == ["v0.6.1", "v0.7.0-rc.1"])
        }
    }

    @Test func getDeployStatusReportsTheOfferedPrerelease() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "deploy-rc-mcp-admin", role: "admin")
            try writeStatus(prerelease: "v0.6.0-rc.11")
            let context = adminMCPContext(app, subject: "deploy-rc-mcp-admin")
            let output = try await GetDeployStatusTool().execute(.init(), context)
            #expect(output.prereleaseVersion == "v0.6.0-rc.11")
        }
    }
}
