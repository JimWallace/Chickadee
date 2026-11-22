// Tests/APITests/PageFixtures/ElementaryPageFixtures+AdminDeployment.swift
//
// The admin Deployment page (docs/release-gate.md), rendered for
// ElementaryPageGuardTests: a held minor with notes and a contract change, an
// approved release while paused, a database upgrade that rolled back or failed,
// and a host with no deploy daemon.

import Elementary
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {

    static var adminDeploymentPage: ElementaryPageFixture {
        let notes = DeployPendingNotes(
            deployedVersion: "0.5.980", heldVersion: "v0.6.0",
            releases: [
                .init(
                    tag: "v0.6.0", name: "Chickadee v0.6.0", publishedAt: "2026-11-20T00:00:00Z",
                    url: "https://github.com/example/releases/v0.6.0",
                    body: "### Changed\n\n- **Kernels.** Re-vendored (#3100).\n- A fix (#3099).")
            ],
            minorReleasePullRequests: [
                .init(number: 3100, title: "Re-vendor the xeus kernels", url: "https://github.com/example/pull/3100")
            ])
        let history = [
            AdminDeploymentView.HistoryRow(
                ts: "2026-11-20T10:00:00Z", version: "v0.6.0", action: "gate", result: "held",
                detail: "minor release; awaiting approval (mode gated-minors)", user: nil),
            AdminDeploymentView.HistoryRow(
                ts: "2026-11-20T09:00:00Z", version: "", action: "request", result: "refused",
                detail: "rollback is a host action, not a request (1.json)", user: "ada"),
            // Long unbroken values, as the daemon writes them: an image
            // digest and a log path. Each must wrap in its own column.
            AdminDeploymentView.HistoryRow(
                ts: "2026-11-20T08:00:00Z", version: "v0.5.989", action: "deploy", result: "start",
                detail: "ghcr.io/jimwallace/chickadee@sha256:"
                    + "948edcab4f4965a40c1408b165baee1a26b3bc22f476b5d7a10963932e8b8ef6a",
                user: nil),
            AdminDeploymentView.HistoryRow(
                ts: "2026-11-20T07:00:00Z", version: "v0.5.989", action: "db-upgrade", result: "failed",
                detail: "/var/lib/chickadee-deploy/logs/db-upgrade-20261121T100000Z-v0.5.989-postgresql-16-to-18.log",
                user: nil),
        ]
        func view(
            available: Bool, paused: Bool, held: AdminDeploymentView.Held?, mode: DeployMode
        )
            -> AdminDeploymentView
        {
            AdminDeploymentView(
                available: available, stateDirectory: "/deploy-state", state: held == nil ? "idle" : "pending_approval",
                detail: "release v0.6.0 needs approval", deployedVersion: "0.5.980", latestSeen: "v0.6.0",
                paused: paused, mode: mode, channel: paused ? "prereleases" : "releases",
                updatedAt: "2026-11-20T10:00:00Z", held: held,
                waitingRequests: paused ? 1 : 0, canSendRequests: available, history: available ? history : [])
        }
        func render(_ view: AdminDeploymentView, flash: FlashMessages = FlashMessages()) -> String {
            AdminDeploymentPage(page: page(currentUser: signedInAdmin), flash: flash, view: view).render()
        }
        let held = AdminDeploymentView.makeHeld(version: "v0.6.0", approved: false, notes: notes)
        let approved = AdminDeploymentView.makeHeld(version: "v0.6.0", approved: true, notes: nil)
        // Production up to date, with the newest pre-release offered on the
        // Coming next card.
        var offered = view(available: true, paused: false, held: nil, mode: .gatedMinors)
        offered.prerelease = AdminDeploymentView.makeHeld(
            version: "v0.6.0-rc.11", approved: false,
            notes: DeployPendingNotes(
                deployedVersion: "0.5.980", heldVersion: "v0.6.0-rc.11",
                releases: [
                    .init(
                        tag: "v0.6.0-rc.11", name: "Chickadee v0.6.0-rc.11", publishedAt: "2026-11-20T00:00:00Z",
                        url: "https://github.com/example/releases/v0.6.0-rc.11",
                        body: "### Removed\n\n- **The runner's `--worker-secret` flag** (#3106).")
                ],
                minorReleasePullRequests: [
                    .init(number: 3106, title: "Remove the runner's --worker-secret flag", url: nil)
                ]))
        // A held release that raises deploy/db-target-major: the daemon
        // upgrades PostgreSQL before it deploys it, and the last attempt
        // rolled back.
        var upgrading = view(
            available: true, paused: false,
            held: AdminDeploymentView.makeHeld(
                version: "v0.7.0", approved: false,
                notes: DeployPendingNotes(
                    deployedVersion: "0.5.980", heldVersion: "v0.7.0", releases: [], minorReleasePullRequests: [],
                    dbTargetMajor: 18),
                runningMajor: 16),
            mode: .gatedMinors)
        upgrading.dbRunningMajor = 16
        upgrading.dbUpgradeState = "rolled_back"
        upgrading.dbUpgradeDetail = "16->18 for v0.7.0 rolled back at restore"
        // The same release held again with no notes yet: the warning comes
        // from the status file's target. Then nothing held, and the alert sits
        // above the running card.
        var failedWithoutNotes = view(
            available: true, paused: false,
            held: AdminDeploymentView.makeHeld(
                version: "v0.7.0", approved: false, notes: nil, runningMajor: 16, statusTargetMajor: 18),
            mode: .gatedMinors)
        failedWithoutNotes.dbRunningMajor = 16
        failedWithoutNotes.dbTargetMajor = 18
        failedWithoutNotes.dbUpgradeState = "failed"
        failedWithoutNotes.dbUpgradeDetail =
            "16->18 for v0.7.0 failed: stopped before the app went down; nothing changed. "
            + "Log /var/lib/chickadee-deploy/logs/db-upgrade-20261121T100000Z.log"
        var failedNothingHeld = view(available: true, paused: false, held: nil, mode: .gatedMinors)
        failedNothingHeld.dbRunningMajor = 16
        failedNothingHeld.dbTargetMajor = 18
        failedNothingHeld.dbUpgradeState = "rolled_back"
        failedNothingHeld.dbUpgradeDetail =
            "16->18 for v0.7.0 rolled_back: rolled back to PostgreSQL 16; the old app runs. "
            + "Log /var/lib/chickadee-deploy/logs/db-upgrade-20261121T100000Z.log"
        return ElementaryPageFixture(
            typeName: "AdminDeploymentPage",
            archetype: .adminTabbed,
            renders: [
                render(view(available: true, paused: false, held: held, mode: .gatedMinors)),
                render(
                    view(available: true, paused: true, held: approved, mode: .manual),
                    flash: FlashMessages(success: "Approved; it deploys on the daemon’s next poll.")),
                render(offered),
                render(upgrading),
                render(failedWithoutNotes),
                render(failedNothingHeld),
                render(view(available: false, paused: false, held: nil, mode: .gatedMinors)),
            ]
        )
    }
}
