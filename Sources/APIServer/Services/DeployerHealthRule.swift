// APIServer/Services/DeployerHealthRule.swift
//
// The `deployerUnhealthy` health rule: the auto-deploy daemon on the host
// (deploy/chickadee-deployer.sh) has stopped deploying, or has stopped running.
// It writes status.json into the deploy state directory, which is mounted
// read-only into this container. Until this rule, a deploy that was `stuck` or
// failing, or a daemon that had died, showed only to someone who opened the
// admin MCP: nothing paged, and prod could run an old release for hours.

import Core
import Foundation
import Vapor

/// The status file the deploy daemon writes (`write_status` in
/// deploy/chickadee-deployer.sh). Every field is optional: an old daemon may
/// write fewer.
struct DeployerStatus: Decodable, Sendable {
    let state: String?
    let detail: String?
    let deployedVersion: String?
    let latestSeen: String?
    let paused: Bool?
    let updatedAt: String?
}

/// The daemon writes its status on every poll (five minutes by default), so a
/// status this old means the daemon has stopped.
let deployerStatusStaleAfterSeconds: TimeInterval = 1800

/// States in which the daemon is not deploying the latest release, and needs an
/// operator. `disk_low`: the host has too little free space to pull a release
/// image, so the daemon holds the deploy rather than fill the disk.
let deployerUnhealthyStates: Set<String> = ["stuck", "error", "certificate_invalid", "disk_low"]

/// Decides the rule from the daemon's last status.
///
/// No status at all is not a firing condition: a deployment without the daemon
/// (development, a VM install) has none, and that is the correct answer. A
/// paused daemon is the operator's own choice, so it does not fire either.
func decideDeployerUnhealthy(
    status: DeployerStatus?,
    now: Date,
    staleAfterSeconds: TimeInterval = deployerStatusStaleAfterSeconds
) -> RuleEvaluation {
    guard let status else { return .ok }
    var details: [String: String] = [:]
    if let state = status.state { details["state"] = state }
    if let deployed = status.deployedVersion { details["deployed_version"] = deployed }
    if let latest = status.latestSeen { details["latest_seen"] = latest }
    if let updatedAt = status.updatedAt { details["updated_at"] = updatedAt }

    if let state = status.state, deployerUnhealthyStates.contains(state) {
        let detail = status.detail.map { ": \($0)" } ?? ""
        return RuleEvaluation(
            isFiring: true, summary: "The auto-deploy daemon reports \(state)\(detail)", details: details)
    }
    guard status.paused != true, status.state != "paused" else { return .ok }

    guard let updatedAt = status.updatedAt.flatMap({ iso8601Date($0) }) else {
        return .ok
    }
    let age = now.timeIntervalSince(updatedAt)
    guard age > staleAfterSeconds else { return .ok }
    details["seconds_since_update"] = String(Int(age))
    return RuleEvaluation(
        isFiring: true,
        summary:
            "The auto-deploy daemon has not written its status for \(Int(age / 60)) min; "
            + "it may have stopped. Check chickadee-deployer on the host.",
        details: details)
}

/// Reads status.json from the deploy state directory and decides the rule.
func evaluateDeployerUnhealthy(on application: Application, now: Date) -> RuleEvaluation {
    let path = URL(fileURLWithPath: application.deployStateDirectory)
        .appendingPathComponent("status.json")
    let status = (try? Data(contentsOf: path)).flatMap { try? JSONDecoder().decode(DeployerStatus.self, from: $0) }
    return decideDeployerUnhealthy(status: status, now: now)
}
