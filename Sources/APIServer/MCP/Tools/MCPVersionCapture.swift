// APIServer/MCP/Tools/MCPVersionCapture.swift
//
// Automatic content-version capture for the MCP write tools
// (docs/assignment-versioning.md).
//
// Rather than asking each of the ~16 content-mutating tools to remember two
// bookkeeping calls, capture hangs off the seam every one of them already goes
// through: `ToolContext.authorizedAssignmentAndSetupForWrite`. Resolving a
// setup for write registers it here (and seeds its baseline, which by
// construction happens before the tool mutates anything); the dispatcher
// snapshots every registered setup after the call succeeds.
//
// The consequence worth stating plainly: a NEW write tool that resolves its
// setup through the standard seam is versioned without its author doing
// anything. `MCPVersionCaptureCoverageTests` is what keeps that true — a write
// tool that reaches a setup another way has to say so out loud.
//
// Version rows are written on `ToolContext.mainDB`, never the least-privilege
// `.mcp` pool. `assignment_versions` is deliberately NOT granted to the
// `chickadee_mcp` role (deploy/sql/mcp-least-privilege-role.sql): a snapshot is
// a system side effect of the call, not agent-facing content access — the same
// reasoning that routes the personalization-seed write and the content-edit
// regrade to the owner pool.

import Fluent
import Foundation
import Vapor

/// Collects the setups an MCP call resolved for write, so the dispatcher can
/// snapshot them once the call succeeds.
///
/// Reference type held by the per-request `ToolContext` (a struct), so a tool
/// registering a setup is visible to the dispatcher that invoked it.
final class MCPVersionCaptureScope: @unchecked Sendable {
    // @unchecked Sendable: the only mutable state is `pending`, and every
    // access is inside `lock`. The box is shared between the tool body and the
    // dispatcher that awaits it, so it crosses no isolation domain unguarded.
    private let lock = NSLock()
    private var pending: [String: APITestSetup] = [:]

    /// Registers a setup as touched by the current call. Idempotent per setup.
    func register(_ setup: APITestSetup) {
        guard let id = setup.id else { return }
        lock.lock()
        defer { lock.unlock() }
        pending[id] = setup
    }

    /// Returns the registered setups and clears the scope, so a batched second
    /// call can't re-snapshot the first call's setups.
    func drain() -> [APITestSetup] {
        lock.lock()
        defer { lock.unlock() }
        let setups = Array(pending.values)
        pending.removeAll()
        return setups
    }
}

extension ToolContext {
    /// Seeds the pre-edit baseline for `setup` and registers it for a
    /// post-call snapshot.
    ///
    /// Called from the write seam, i.e. before the tool has changed anything —
    /// which is the only moment the pre-edit state is still capturable, and
    /// therefore the only moment a first-ever edit can be made recoverable.
    ///
    /// Best-effort in both directions: an assignment edit must not fail because
    /// its history could not be written.
    func beginContentWrite(setup: APITestSetup) async {
        versionCapture.register(setup)
        do {
            _ = try await AssignmentVersionStore.ensureBaseline(
                setup: setup,
                testSetupsDirectory: request.application.testSetupsDirectory,
                on: mainDB)
        } catch {
            logger.warning(
                "assignment version baseline failed",
                metadata: [
                    "setup": .string(setup.id ?? "?"), "error": .string("\(error)"),
                ])
        }
    }

    /// Snapshots every setup registered during this call. Invoked by the
    /// dispatcher after a write tool returns successfully; a failed call
    /// registers nothing worth recording because its edit did not persist.
    func finishContentWrites(tool: String) async {
        let setups = versionCapture.drain()
        guard !setups.isEmpty else { return }

        let actor = try? await requireEligibleSubject(tool: tool)
        for setup in setups {
            // Re-read: the tool mutated its own in-memory copy, and for a
            // manifest edit that copy is the one that was saved — but a tool
            // that reloaded or replaced the row would otherwise be snapshotted
            // from a stale object.
            let current = (try? await APITestSetup.find(setup.id ?? "", on: mainDB)) ?? setup
            _ = await AssignmentVersionStore.recordBestEffort(
                setup: current,
                request: AssignmentVersionRequest(
                    origin: AssignmentVersionOrigin.mcp(tool: tool), actor: actor),
                testSetupsDirectory: request.application.testSetupsDirectory,
                logger: logger,
                on: mainDB)
        }
    }
}
