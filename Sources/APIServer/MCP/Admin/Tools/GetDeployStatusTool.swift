// APIServer/MCP/Admin/Tools/GetDeployStatusTool.swift
//
// Read tool: report the zero-downtime auto-deploy daemon's current state, from
// the status file it writes (status.json in the deploy state dir, mounted
// read-only into the container). Lets an operator/agent see what version is
// live, what release the daemon last saw, whether auto-deploy is paused, and
// the deploy mode, and which release waits for approval — without SSH.
//
// Read-only and side-effect-free: it reads a small JSON file the daemon owns.
// Deploy CONTROL is deliberately NOT here. Approve, mode and pause are
// requests from the admin Deployment page, which the daemon validates;
// rollback is a host action (docs/release-gate.md). This surface stays
// read-only.

import Core
import Foundation
import Vapor

struct GetDeployStatusTool: DiagnosticTool {
    struct Input: Decodable, Sendable {}

    struct Output: Encodable, Sendable {
        /// false when the status file is missing/unreadable (daemon not running,
        /// or its state dir is not mounted into this container).
        let available: Bool
        /// idle | deploying | waiting_for_image | pending_approval | paused | error |
        /// stuck | certificate_invalid (nil if unavailable). See
        /// docs/zero-downtime-deploy.md for what each one means.
        let state: String?
        /// The version currently live, per the daemon.
        let deployedVersion: String?
        /// The latest release tag the daemon last observed.
        let latestSeen: String?
        /// Human-readable detail for the current state.
        let detail: String?
        /// Whether auto-deploy is currently paused.
        let paused: Bool?
        /// The deploy mode: autonomous | gated-minors | manual. A daemon with
        /// no mode file runs in gated-minors; nil from a daemon older than the
        /// release gate.
        let mode: String?
        /// The release channel: releases (production) or prereleases (the dev
        /// server). Host-only; nil from a daemon older than the channel.
        let channel: String?
        /// The release the daemon holds for approval, or nil when none waits.
        let heldVersion: String?
        /// The held release an admin approved, which deploys on the next poll.
        let approvedVersion: String?
        /// When the daemon last wrote this status (ISO-8601 UTC).
        let updatedAt: String?
        /// The commit of the daemon's own scripts on the host (12 characters).
        /// The daemon brings them to each release it deploys; nil from a daemon
        /// older than that.
        let scriptsRevision: String?
        /// Explanation when `available` is false.
        let note: String?
    }

    static let name = "get_deploy_status"
    static let description =
        "Report the zero-downtime auto-deploy daemon's current state from the status file it "
        + "writes: which version is live (deployedVersion), the latest release it has seen "
        + "(latestSeen), whether auto-deploy is paused, the deploy mode (autonomous, gated-minors "
        + "or manual), the release channel (releases or prereleases), the release held for approval (heldVersion, with state=pending_approval) and "
        + "whether an admin approved it (approvedVersion), the last update time, and the commit of the "
        + "daemon's own scripts on the host (scriptsRevision). Returns available=false "
        + "if the daemon is not running or its state dir is not mounted. Read-only; reads a small "
        + "JSON file the daemon owns and touches no course, student, or database state. Deploy "
        + "control is not exposed here: approve, mode and pause are on the admin Deployment page, and "
        + "rollback is a host action."
    static let inputSchema: JSONValue = MCPSchema.noArgumentsInput

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        let path = URL(fileURLWithPath: context.request.application.deployStateDirectory)
            .appendingPathComponent("status.json")

        guard let data = try? Data(contentsOf: path) else {
            return Output(
                available: false, state: nil, deployedVersion: nil, latestSeen: nil,
                detail: nil, paused: nil, mode: nil, channel: nil, heldVersion: nil, approvedVersion: nil,
                updatedAt: nil,
                scriptsRevision: nil,
                note: "No deploy status at \(path.path) — the auto-deploy daemon may not be "
                    + "running, or its state directory is not mounted into this container.")
        }
        guard let status = try? JSONDecoder().decode(DeployStatusFile.self, from: data) else {
            return Output(
                available: false, state: nil, deployedVersion: nil, latestSeen: nil,
                detail: nil, paused: nil, mode: nil, channel: nil, heldVersion: nil, approvedVersion: nil,
                updatedAt: nil,
                scriptsRevision: nil,
                note: "Deploy status file at \(path.path) could not be parsed.")
        }
        return Output(
            available: true,
            state: status.state,
            deployedVersion: status.deployedVersion,
            latestSeen: status.latestSeen,
            detail: status.detail,
            paused: status.paused,
            mode: status.mode,
            channel: status.channel,
            heldVersion: status.heldVersion,
            approvedVersion: status.approvedVersion,
            updatedAt: status.updatedAt,
            scriptsRevision: status.scriptsRevision,
            note: nil)
    }
}
