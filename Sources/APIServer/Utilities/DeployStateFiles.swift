// APIServer/Utilities/DeployStateFiles.swift
//
// The files the deploy daemon writes into its state folder, as the app reads
// them (deploy/chickadee-deployer.sh; docs/release-gate.md). DeployStateFolder
// reads them.

import Foundation

/// status.json, as the daemon writes it (`write_status`). Every field is
/// optional: an older daemon writes fewer.
struct DeployStatusFile: Decodable, Sendable {
    let state: String?
    let deployedVersion: String?
    let latestSeen: String?
    let detail: String?
    let paused: Bool?
    let mode: String?
    /// The release channel: `releases` (production) or `prereleases` (the
    /// dev server). Set only on the host; nil from an older daemon.
    let channel: String?
    let heldVersion: String?
    let approvedVersion: String?
    /// On the `releases` channel, the newest pre-release newer than
    /// production, offered for an explicit approval. Nil from an older
    /// daemon, on `prereleases`, and when none is newer.
    let prereleaseVersion: String?
    let scriptsRevision: String?
    let updatedAt: String?
    /// The PostgreSQL major version the `db` service runs, as the daemon last
    /// read it. Nil from an older daemon, or when the database did not answer.
    var dbRunningMajor: Int?
    /// The major version the checked-out release declares in
    /// `deploy/db-target-major`. Nil when the release declares none.
    var dbTargetMajor: Int?
    /// The database major upgrade the daemon runs before a release that
    /// raises the target: none, pending, running, done, failed or
    /// rolled_back (docs/release-gate.md, "Database major upgrades").
    var dbUpgradeState: String?
    /// What the last upgrade did, with the path of its log.
    var dbUpgradeDetail: String?
}

/// pending-notes.json: what approving the held release would ship. The
/// daemon writes prerelease-notes.json in the same shape for the offered
/// pre-release, with its tag in `heldVersion`.
struct DeployPendingNotes: Decodable, Sendable {
    struct Release: Decodable, Sendable {
        let tag: String
        let name: String?
        let publishedAt: String?
        let url: String?
        let body: String?
    }

    struct PullRequest: Decodable, Sendable {
        let number: Int
        let title: String?
        let url: String?
    }

    let deployedVersion: String?
    let heldVersion: String?
    let releases: [Release]?
    let minorReleasePullRequests: [PullRequest]?
    /// The PostgreSQL major version this release declares in
    /// `deploy/db-target-major`. Nil when it declares none, or from an older
    /// daemon.
    var dbTargetMajor: Int?
}

/// One line of history.jsonl.
struct DeployHistoryRecord: Decodable, Sendable {
    let ts: String?
    let version: String?
    let action: String?
    let result: String?
    let detail: String?
    /// The admin who sent a request; absent for the daemon's own events.
    let user: String?
}
