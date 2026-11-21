// Tests/APITests/Admin/AdminDeploymentDatabaseUpgradeTests.swift
//
// A release that raises deploy/db-target-major makes the deploy daemon upgrade
// PostgreSQL before it deploys the release (docs/release-gate.md, "Database
// major upgrades"). The daemon reports the running major and the upgrade state
// in status.json and each release's target in its notes file. The admin page
// says so on the held and Coming next cards, and a failed or rolled-back
// upgrade fires the deployerUnhealthy rule. The daemon side is in
// scripts/test-chickadee-deployer.sh.

import Elementary
import Foundation
import Testing

@testable import APIServer

@Suite struct AdminDeploymentDatabaseUpgradeTests {

    private static let banner = "This release upgrades PostgreSQL from 16 to 18, and the app is down for a few minutes."
    private static let upgradeNote =
        "It upgrades the database, then deploys on the daemon’s next poll, unless paused."

    /// A state folder with status.json and, for each given file name, notes
    /// for `version` that declare `target`. The caller removes it.
    private static func makeFolder(
        status: String, notes: [String: (version: String, target: Int?)]
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deploy-state-db-\(UUID().uuidString)")
        // The requests folder, so the page shows the approve form.
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("requests"), withIntermediateDirectories: true)
        try status.write(to: url.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        for (file, release) in notes {
            let target = release.target.map(String.init) ?? "null"
            let body = """
                {"deployedVersion":"0.6.3","heldVersion":"\(release.version)","releases":[],\
                "minorReleasePullRequests":[],"dbTargetMajor":\(target)}
                """
            try body.write(to: url.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return url
    }

    private static func status(
        held: String? = nil, prerelease: String? = nil, running: Int? = 16, target: Int = 16,
        upgrade: String = "none", detail: String? = nil
    ) -> String {
        func json(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
        return """
            {"state":"pending_approval","deployedVersion":"0.6.3","latestSeen":"v0.7.0","detail":"",\
            "paused":false,"mode":"gated-minors","channel":"releases","heldVersion":\(json(held)),\
            "approvedVersion":null,"prereleaseVersion":\(json(prerelease)),"updatedAt":"2026-11-21T10:00:00Z",\
            "dbRunningMajor":\(running.map(String.init) ?? "null"),"dbTargetMajor":\(target),\
            "dbUpgradeState":"\(upgrade)","dbUpgradeDetail":\(json(detail))}
            """
    }

    private static func render(_ folder: URL) -> String {
        let view = AdminDeploymentView.make(folder: DeployStateFolder(directory: folder.path))
        return AdminDeploymentPage(
            page: ElementaryPageFixtures.page(currentUser: ElementaryPageFixtures.signedInAdmin), view: view
        ).render()
    }

    @Test func aHeldReleaseThatRaisesTheTargetSaysItUpgradesTheDatabase() throws {
        let folder = try Self.makeFolder(
            status: Self.status(held: "v0.7.0"), notes: ["pending-notes.json": ("v0.7.0", 18)])
        defer { try? FileManager.default.removeItem(at: folder) }
        let view = AdminDeploymentView.make(folder: DeployStateFolder(directory: folder.path))
        #expect(view.held?.databaseUpgrade == .init(fromMajor: 16, toMajor: 18))
        let html = Self.render(folder)
        #expect(html.contains(Self.banner))
        #expect(html.contains("PostgreSQL 16"))
    }

    @Test func theComingNextCardSaysItUpgradesTheDatabase() throws {
        let folder = try Self.makeFolder(
            status: Self.status(prerelease: "v0.7.0-rc.1"),
            notes: ["prerelease-notes.json": ("v0.7.0-rc.1", 18)])
        defer { try? FileManager.default.removeItem(at: folder) }
        let html = Self.render(folder)
        #expect(html.contains("Coming next"))
        #expect(html.contains(Self.banner))
    }

    @Test(arguments: [16, nil] as [Int?])
    func aReleaseThatDoesNotRaiseTheTargetSaysNothingAboutTheDatabase(target: Int?) throws {
        let folder = try Self.makeFolder(
            status: Self.status(held: "v0.7.0"), notes: ["pending-notes.json": ("v0.7.0", target)])
        defer { try? FileManager.default.removeItem(at: folder) }
        let html = Self.render(folder)
        #expect(!html.contains("upgrades PostgreSQL"))
        #expect(html.contains("It deploys on the daemon’s next poll, unless paused."))
    }

    @Test func theApproveNoteSaysTheApprovalUpgradesTheDatabase() throws {
        let folder = try Self.makeFolder(
            status: Self.status(held: "v0.7.0"), notes: ["pending-notes.json": ("v0.7.0", 18)])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(Self.render(folder).contains(Self.upgradeNote))
    }

    /// With no notes, or notes for another release, the warning comes from
    /// the status file's target.
    @Test(arguments: [nil, "v0.6.9"] as [String?])
    func theWarningFallsBackToTheStatusTargetWithoutCurrentNotes(notesVersion: String?) throws {
        let notes = notesVersion.map { ["pending-notes.json": ($0, 16 as Int?)] } ?? [:]
        let folder = try Self.makeFolder(status: Self.status(held: "v0.7.0", target: 18), notes: notes)
        defer { try? FileManager.default.removeItem(at: folder) }
        let view = AdminDeploymentView.make(folder: DeployStateFolder(directory: folder.path))
        #expect(view.held?.hasNotes == false)
        #expect(view.held?.databaseUpgrade == .init(fromMajor: 16, toMajor: 18))
        let html = Self.render(folder)
        #expect(html.contains(Self.banner))
        #expect(html.contains(Self.upgradeNote))
    }

    @Test func anUnknownRunningMajorSaysNothingAboutTheUpgrade() throws {
        let folder = try Self.makeFolder(
            status: Self.status(held: "v0.7.0", running: nil), notes: ["pending-notes.json": ("v0.7.0", 18)])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!Self.render(folder).contains("upgrades PostgreSQL"))
    }

    // MARK: - A failed upgrade

    private static let rolledBackAlert =
        #"<div class="flash flash-error" role="alert">The database upgrade to PostgreSQL 18 failed and was "#
        + "rolled back; the release was not deployed.</div>"
    private static let failedAlert =
        #"<div class="flash flash-error" role="alert">The database upgrade to PostgreSQL 18 failed; "#
        + "the release was not deployed.</div>"

    @Test(arguments: [("rolled_back", rolledBackAlert), ("failed", failedAlert)])
    func aFailedUpgradeRaisesAnAlertOnTheHeldCard(state: String, alert: String) throws {
        let folder = try Self.makeFolder(
            status: Self.status(held: "v0.7.0", upgrade: state, detail: "16->18 for v0.7.0 \(state)"),
            notes: ["pending-notes.json": ("v0.7.0", 18)])
        defer { try? FileManager.default.removeItem(at: folder) }
        let html = Self.render(folder)
        let alertRange = try #require(html.range(of: alert))
        let heldRange = try #require(html.range(of: "Waiting for approval"))
        #expect(alertRange.lowerBound > heldRange.lowerBound)
        #expect(html.components(separatedBy: #"role="alert""#).count == 2)
        #expect(html.contains("<code>\(state)</code>"))
    }

    @Test func withNothingHeldTheAlertSitsAboveTheRunningCard() throws {
        let folder = try Self.makeFolder(
            status: Self.status(target: 18, upgrade: "rolled_back", detail: "rolled back"), notes: [:])
        defer { try? FileManager.default.removeItem(at: folder) }
        let html = Self.render(folder)
        let alertRange = try #require(html.range(of: Self.rolledBackAlert))
        let cardRange = try #require(html.range(of: #"<dl class="detail-grid">"#))
        #expect(alertRange.lowerBound < cardRange.lowerBound)
    }

    @Test(arguments: ["none", "pending", "running", "done"])
    func anUpgradeThatHasNotFailedRaisesNoAlert(state: String) throws {
        let folder = try Self.makeFolder(
            status: Self.status(held: "v0.7.0", target: 18, upgrade: state),
            notes: ["pending-notes.json": ("v0.7.0", 18)])
        defer { try? FileManager.default.removeItem(at: folder) }
        let view = AdminDeploymentView.make(folder: DeployStateFolder(directory: folder.path))
        #expect(view.databaseUpgradeFailure == nil)
        #expect(!Self.render(folder).contains(#"role="alert""#))
    }

    @Test func aRolledBackUpgradeShowsOnTheRunningCard() throws {
        let folder = try Self.makeFolder(
            status: Self.status(upgrade: "rolled_back", detail: "16->18 for v0.7.0 rolled back at restore"),
            notes: [:])
        defer { try? FileManager.default.removeItem(at: folder) }
        let html = Self.render(folder)
        #expect(html.contains("<code>rolled_back</code>"))
        #expect(html.contains("16-&gt;18 for v0.7.0 rolled back at restore"))
    }

    // MARK: - The health rule

    private func deployerStatus(upgrade: String?, paused: Bool = false) -> DeployerStatus {
        DeployerStatus(
            state: paused ? "paused" : "pending_approval", detail: "release v0.7.0 needs approval",
            deployedVersion: "0.6.3", latestSeen: "v0.7.0", paused: paused,
            updatedAt: ISO8601DateFormatter().string(from: Date()), dbUpgradeState: upgrade,
            dbUpgradeDetail: "16->18 for v0.7.0 failed")
    }

    @Test(arguments: ["failed", "rolled_back"])
    func aFailedUpgradeFiresEvenWhilePaused(state: String) {
        for paused in [false, true] {
            let evaluation = decideDeployerUnhealthy(
                status: deployerStatus(upgrade: state, paused: paused), now: Date())
            #expect(evaluation.isFiring)
            #expect(evaluation.summary.contains("16->18 for v0.7.0 failed"))
            #expect(evaluation.details["db_upgrade_state"] == state)
        }
    }

    @Test(arguments: ["none", "pending", "running", "done", nil] as [String?])
    func anUpgradeThatHasNotFailedDoesNotFire(state: String?) {
        #expect(!decideDeployerUnhealthy(status: deployerStatus(upgrade: state), now: Date()).isFiring)
    }

    @Test func aBlockedUpgradeLockIsAnUnhealthyState() {
        let status = DeployerStatus(
            state: "db_upgrade_blocked", detail: ".db-upgrade.lock remains", deployedVersion: "0.6.3",
            latestSeen: "v0.7.0", paused: false, updatedAt: ISO8601DateFormatter().string(from: Date()))
        #expect(decideDeployerUnhealthy(status: status, now: Date()).isFiring)
    }

    @Test func theStatusFileDecodesTheDatabaseFields() throws {
        let data = Data(Self.status(upgrade: "done", detail: "16->18 ok").utf8)
        let decoded = try JSONDecoder().decode(DeployStatusFile.self, from: data)
        #expect(decoded.dbRunningMajor == 16)
        #expect(decoded.dbTargetMajor == 16)
        #expect(decoded.dbUpgradeState == "done")
        #expect(decoded.dbUpgradeDetail == "16->18 ok")
    }
}
