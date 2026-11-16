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
    let heldVersion: String?
    let approvedVersion: String?
    let scriptsRevision: String?
    let updatedAt: String?
}

/// pending-notes.json: what approving the held release would ship.
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
