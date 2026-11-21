// APIServer/Utilities/AdminDeploymentView.swift
//
// What the admin Deployment page shows (docs/release-gate.md, "The admin
// page"): what runs, what waits, and the recent history, read from the deploy
// daemon's state folder. Built once per request from `DeployStateFolder`, so
// the page itself does no I/O.

import Foundation

struct AdminDeploymentView: Sendable {
    /// One release between the deployed version and the held one.
    struct ReleaseNotes: Sendable {
        let tag: String
        let name: String
        let url: String?
        let publishedAt: String?
        let entries: [DeployReleaseNotes.Entry]
    }

    /// A merged pull request labelled `minor-release` that the held release
    /// carries.
    struct ContractPullRequest: Sendable {
        let number: Int
        let title: String
        let url: String?
    }

    /// The release the daemon holds for approval, with what it ships.
    struct Held: Sendable {
        let version: String
        /// True when the daemon recorded the approval and deploys it on its
        /// next poll.
        let isApproved: Bool
        /// False when the daemon has not written the notes for this release.
        let hasNotes: Bool
        let releases: [ReleaseNotes]
        let contractPullRequests: [ContractPullRequest]
    }

    struct HistoryRow: Sendable {
        let ts: String
        let version: String
        let action: String
        let result: String
        let detail: String
        let user: String?

        /// A refused request or a failed step reads as a failure.
        var isFailure: Bool { ["refused", "failed", "rolledback", "abort"].contains(result) }
    }

    /// False when there is no status file: no daemon, or no mount.
    let available: Bool
    let stateDirectory: String
    let state: String?
    let detail: String?
    let deployedVersion: String?
    let latestSeen: String?
    let paused: Bool
    let mode: DeployMode
    /// The release channel, shown read-only: the host sets it. A daemon that
    /// reports none predates the channel and reads only releases/latest, so
    /// `releases` is true of it.
    let channel: String
    let updatedAt: String?
    let held: Held?
    /// On production's channel, the newest pre-release, offered for an
    /// explicit approval: the Coming next card. No mode deploys it.
    var prerelease: Held?
    /// The mode a waiting request asks for, until the daemon reads it on its
    /// next poll. The page checks it, so a second Save is not invited.
    var pendingMode: DeployMode?
    /// Requests written and not yet read by the daemon, which reads them on
    /// every poll.
    let waitingRequests: Int
    /// False when the requests folder is missing, so no action can be sent.
    let canSendRequests: Bool
    let history: [HistoryRow]

    /// How many history lines the page shows.
    static let historyLimit = 20

    static func make(folder: DeployStateFolder) -> AdminDeploymentView {
        let status = folder.status()
        let mode = folder.modeInForce()
        // A request the daemon has not read yet already counts on the page: an
        // approval shows as approved, a mode as chosen. Otherwise the page
        // shows the old state for up to a poll and invites a second request.
        let waiting = folder.waitingRequests()
        func approved(_ version: String) -> Bool {
            status?.approvedVersion == version || waiting.contains(.approve(version: version))
        }
        let pendingMode = DeployRequest.lastMode(in: waiting)
        let heldVersion = status?.heldVersion.flatMap { $0.isEmpty ? nil : $0 }
        let held = heldVersion.map { version in
            makeHeld(version: version, approved: approved(version), notes: folder.pendingNotes())
        }
        let prerelease = status?.prereleaseVersion.flatMap { $0.isEmpty ? nil : $0 }.map { version in
            makeHeld(version: version, approved: approved(version), notes: folder.prereleaseNotes())
        }
        let history = folder.history(limit: historyLimit).map { record in
            HistoryRow(
                ts: record.ts ?? "", version: record.version ?? "", action: record.action ?? "",
                result: record.result ?? "", detail: record.detail ?? "",
                user: record.user.flatMap { $0.isEmpty ? nil : $0 })
        }
        return AdminDeploymentView(
            available: status != nil,
            stateDirectory: folder.directory,
            state: status?.state,
            detail: status?.detail,
            deployedVersion: status?.deployedVersion,
            latestSeen: status?.latestSeen,
            paused: status?.paused ?? false,
            mode: mode,
            channel: status?.channel ?? "releases",
            updatedAt: status?.updatedAt,
            held: held,
            prerelease: prerelease,
            pendingMode: pendingMode == mode ? nil : pendingMode,
            waitingRequests: folder.waitingRequestCount(),
            canSendRequests: FileManager.default.fileExists(atPath: folder.requestsFolder.path),
            history: history)
    }

    /// A link from pending-notes.json, kept only when it is https. The daemon
    /// writes them from the GitHub API, so this is a second guard, not the
    /// first.
    static func httpsOnly(_ url: String?) -> String? {
        guard let url, url.hasPrefix("https://") else { return nil }
        return url
    }

    /// The held release and its notes. Notes written for another release are
    /// stale and are not shown.
    static func makeHeld(version: String, approved: Bool, notes: DeployPendingNotes?) -> Held {
        guard let notes, notes.heldVersion == version else {
            return Held(version: version, isApproved: approved, hasNotes: false, releases: [], contractPullRequests: [])
        }
        let contract = (notes.minorReleasePullRequests ?? []).map {
            ContractPullRequest(number: $0.number, title: $0.title ?? "", url: httpsOnly($0.url))
        }
        let numbers = Set(contract.map(\.number))
        let releases = (notes.releases ?? []).map { release in
            ReleaseNotes(
                tag: release.tag, name: release.name ?? release.tag, url: httpsOnly(release.url),
                publishedAt: release.publishedAt,
                entries: DeployReleaseNotes.entries(in: release.body ?? "", contractPullRequests: numbers))
        }
        return Held(
            version: version, isApproved: approved, hasNotes: true, releases: releases,
            contractPullRequests: contract)
    }
}
