// APIServer/MCP/Admin/Tools/GetDeployStatusTool.swift
//
// Read tool: report the zero-downtime auto-deploy daemon's current state, from
// the status file it writes (status.json in the deploy state dir, mounted
// read-only into the container). Lets an operator/agent see what version is
// live, what release the daemon last saw, whether auto-deploy is paused, and
// whether a major bump is awaiting approval — without SSH.
//
// Read-only and side-effect-free: it reads a small JSON file the daemon owns.
// Deploy CONTROL (pause / approve / rollback) is deliberately NOT here — it
// stays a host-side action so the read-only admin surface keeps its guarantee
// and a compromised app (the IPC dir is mounted read-only) cannot move traffic.

import Core
import Foundation
import Vapor

struct GetDeployStatusTool: DiagnosticTool {
    struct Input: Decodable, Sendable {}

    struct Output: Encodable, Sendable {
        /// false when the status file is missing/unreadable (daemon not running,
        /// or its state dir is not mounted into this container).
        let available: Bool
        /// idle | deploying | pending_approval | paused | error (nil if unavailable).
        let state: String?
        /// The version currently live, per the daemon.
        let deployedVersion: String?
        /// The latest release tag the daemon last observed.
        let latestSeen: String?
        /// Human-readable detail for the current state.
        let detail: String?
        /// Whether auto-deploy is currently paused.
        let paused: Bool?
        /// When the daemon last wrote this status (ISO-8601 UTC).
        let updatedAt: String?
        /// Explanation when `available` is false.
        let note: String?
    }

    /// Mirrors the JSON the daemon writes (deploy/chickadee-deployer.sh).
    private struct StatusFile: Decodable {
        let state: String?
        let deployedVersion: String?
        let latestSeen: String?
        let detail: String?
        let paused: Bool?
        let updatedAt: String?
    }

    static let name = "get_deploy_status"
    static let description =
        "Report the zero-downtime auto-deploy daemon's current state from the status file it "
        + "writes: which version is live (deployedVersion), the latest release it has seen "
        + "(latestSeen), whether auto-deploy is paused, whether a major bump is awaiting "
        + "approval (state=pending_approval), and the last update time. Returns available=false "
        + "if the daemon is not running or its state dir is not mounted. Read-only; reads a small "
        + "JSON file the daemon owns and touches no course, student, or database state. Deploy "
        + "control (pause/approve/rollback) is a host-side action, not exposed here."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        try await context.requireAdminSubject(tool: Self.name)

        let path = URL(fileURLWithPath: context.request.application.deployStateDirectory)
            .appendingPathComponent("status.json")

        guard let data = try? Data(contentsOf: path) else {
            return Output(
                available: false, state: nil, deployedVersion: nil, latestSeen: nil,
                detail: nil, paused: nil, updatedAt: nil,
                note: "No deploy status at \(path.path) — the auto-deploy daemon may not be "
                    + "running, or its state directory is not mounted into this container.")
        }
        guard let status = try? JSONDecoder().decode(StatusFile.self, from: data) else {
            return Output(
                available: false, state: nil, deployedVersion: nil, latestSeen: nil,
                detail: nil, paused: nil, updatedAt: nil,
                note: "Deploy status file at \(path.path) could not be parsed.")
        }
        return Output(
            available: true,
            state: status.state,
            deployedVersion: status.deployedVersion,
            latestSeen: status.latestSeen,
            detail: status.detail,
            paused: status.paused,
            updatedAt: status.updatedAt,
            note: nil)
    }
}
