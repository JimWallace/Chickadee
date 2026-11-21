// Tests/APITests/Admin/AdminDeploymentPendingRequestTests.swift
//
// A request waits in requests/ until the deploy daemon's next poll, up to five
// minutes. On 2026-11-18 the page went on showing the old mode meanwhile, and
// the same mode change was sent four times, each one audited and each one
// replayed into the deploy history. Now the page shows what waits, a request
// identical to a waiting one is not written again, and saving the mode in
// force with nothing waiting sends nothing.

import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2)))
final class AdminDeploymentPendingRequestTests {

    let app: Application
    let stateDirectory: URL

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-deploy-pending")
        stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deploy-state-pending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: stateDirectory.appendingPathComponent("requests"), withIntermediateDirectories: true)
        app.deployStateDirectory = stateDirectory.path
    }

    deinit {
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    private func writeStatus(held: String? = nil, mode: String = "gated-minors") throws {
        let heldJSON = held.map { "\"\($0)\"" } ?? "null"
        let status = """
            {"state":"\(held == nil ? "idle" : "pending_approval")","deployedVersion":"0.5.989",\
            "latestSeen":"v0.5.989","detail":"idle","paused":false,"mode":"\(mode)","channel":"releases",\
            "heldVersion":\(heldJSON),"approvedVersion":null,"updatedAt":"2026-11-20T10:00:00Z"}
            """
        try status.write(
            to: stateDirectory.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
    }

    private func requestCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: stateDirectory.appendingPathComponent("requests").path)
            .count(where: { $0.hasSuffix(".json") })
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

    @Test func aSecondIdenticalModeRequestIsNotWritten() async throws {
        try await withApp(app) { app in
            try writeStatus(mode: "autonomous")
            let cookie = try await loginAsAdmin("deploy_pending_mode", on: app)
            let first = try await post("/admin/deployment/mode", fields: ["mode": "gated-minors"], cookie: cookie)
            let second = try await post("/admin/deployment/mode", fields: ["mode": "gated-minors"], cookie: cookie)
            #expect(first == "/admin/deployment?notice=modeRequested")
            #expect(second == "/admin/deployment?notice=alreadyWaiting")
            #expect(try requestCount() == 1)
        }
    }

    @Test func savingTheModeInForceWithNothingWaitingSendsNothing() async throws {
        try await withApp(app) { app in
            try writeStatus(mode: "gated-minors")
            let cookie = try await loginAsAdmin("deploy_pending_same", on: app)
            let location = try await post("/admin/deployment/mode", fields: ["mode": "gated-minors"], cookie: cookie)
            #expect(location == "/admin/deployment?notice=modeUnchanged")
            #expect(try requestCount() == 0)
        }
    }

    @Test func switchingBackBeforeThePollIsStillSent() async throws {
        try await withApp(app) { app in
            try writeStatus(mode: "gated-minors")
            let cookie = try await loginAsAdmin("deploy_pending_back", on: app)
            _ = try await post("/admin/deployment/mode", fields: ["mode": "manual"], cookie: cookie)
            let back = try await post("/admin/deployment/mode", fields: ["mode": "gated-minors"], cookie: cookie)
            #expect(back == "/admin/deployment?notice=modeRequested")
            #expect(try requestCount() == 2)
        }
    }

    @Test func aSecondApprovalOfTheSameReleaseIsNotWritten() async throws {
        try await withApp(app) { app in
            try writeStatus(held: "v0.6.0")
            let cookie = try await loginAsAdmin("deploy_pending_approve", on: app)
            _ = try await post("/admin/deployment/approve", fields: ["version": "v0.6.0"], cookie: cookie)
            let second = try await post("/admin/deployment/approve", fields: ["version": "v0.6.0"], cookie: cookie)
            #expect(second == "/admin/deployment?notice=alreadyWaiting")
            #expect(try requestCount() == 1)
        }
    }

    @Test func thePageShowsTheWaitingModeAndApproval() async throws {
        try await withApp(app) { app in
            try writeStatus(held: "v0.6.0", mode: "autonomous")
            let cookie = try await loginAsAdmin("deploy_pending_page", on: app)
            _ = try await post("/admin/deployment/mode", fields: ["mode": "manual"], cookie: cookie)
            _ = try await post("/admin/deployment/approve", fields: ["version": "v0.6.0"], cookie: cookie)
            let html = try await getHTML("/admin/deployment", cookie: cookie, on: app)
            #expect(html.contains(#"value="manual" checked"#))
            #expect(!html.contains(#"value="autonomous" checked"#))
            #expect(html.contains("Manual requested; the deployer applies it at its next poll."))
            #expect(!html.contains(#"action="/admin/deployment/approve""#))
            #expect(html.contains("Approved"))
        }
    }
}
