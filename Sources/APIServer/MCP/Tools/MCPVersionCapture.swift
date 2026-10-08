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
        await versionCapture.begin(
            setup: setup, testSetupsDirectory: request.application.testSetupsDirectory,
            logger: logger, on: mainDB)
    }

    /// Snapshots every setup registered during this call. Invoked by the
    /// dispatcher after a write tool returns successfully; a failed call
    /// registers nothing worth recording because its edit did not persist.
    func finishContentWrites(tool: String) async {
        guard !versionCapture.isEmpty else { return }
        await versionCapture.recordRegistered(
            origin: AssignmentVersionOrigin.mcp(tool: tool),
            actor: try? await requireEligibleSubject(),
            testSetupsDirectory: request.application.testSetupsDirectory,
            logger: logger,
            on: mainDB)
    }
}
