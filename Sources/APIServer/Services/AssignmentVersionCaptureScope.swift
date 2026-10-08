// APIServer/Services/AssignmentVersionCaptureScope.swift
//
// The per-request record of which setups a write touched, and the two steps
// around it: seed the pre-edit baseline when a setup is resolved for write, and
// snapshot each registered setup once the write succeeds
// (docs/assignment-versioning.md).
//
// The web middleware and the MCP dispatcher each had their own copy of this
// type and of the record loop (#2259, item 4). The copies had begun to differ:
// only the web scope could say whether it was empty. Each side now keeps only
// its seam, its origin label and its database, and passes them in.

import Fluent
import Foundation
import Synchronization
import Vapor

/// Collects the setups that one request (web) or one tool call (MCP) resolved
/// for write, so they can be snapshotted once it succeeds.
///
/// A reference type, so the handler or tool that registers a setup and the
/// middleware or dispatcher that records it see the same set.
final class AssignmentVersionCaptureScope: Sendable {
    /// Shared between the handler and the caller that awaits it.
    private let pending = Mutex<[String: APITestSetup]>([:])

    /// Registers a setup as touched by the current write. Idempotent per setup.
    func register(_ setup: APITestSetup) {
        guard let id = setup.id else { return }
        pending.withLock { $0[id] = setup }
    }

    /// Returns the registered setups and clears the scope, so a later write
    /// that shares the scope cannot snapshot them again.
    func drain() -> [APITestSetup] {
        pending.withLock { pending in
            let setups = Array(pending.values)
            pending.removeAll()
            return setups
        }
    }

    var isEmpty: Bool {
        pending.withLock { $0.isEmpty }
    }

    /// Registers `setup` and seeds its pre-edit baseline.
    ///
    /// Called from the write seam, before the handler or tool has changed
    /// anything. That is the only moment the pre-edit state can still be
    /// captured, so it is the only moment a first-ever edit can be made
    /// recoverable. Best-effort: an edit must not fail because its history
    /// could not be written.
    func begin(setup: APITestSetup, testSetupsDirectory: String, logger: Logger, on db: any Database) async {
        register(setup)
        do {
            _ = try await AssignmentVersionStore.ensureBaseline(
                setup: setup, testSetupsDirectory: testSetupsDirectory, on: db)
        } catch {
            logger.warning(
                "assignment version baseline failed",
                metadata: [
                    "setup": .string(setup.id ?? "?"), "error": .string("\(error)"),
                ])
        }
    }

    /// Snapshots every registered setup, then clears the scope.
    func recordRegistered(
        origin: String, actor: APIUser?, testSetupsDirectory: String, logger: Logger, on db: any Database
    ) async {
        for setup in drain() {
            // Re-read, so that a handler or tool that reloaded or replaced the
            // row is snapshotted from what persisted, not from a stale object.
            let current = (try? await APITestSetup.find(setup.id ?? "", on: db)) ?? setup
            _ = await AssignmentVersionStore.recordBestEffort(
                setup: current,
                request: AssignmentVersionRequest(origin: origin, actor: actor),
                testSetupsDirectory: testSetupsDirectory,
                logger: logger,
                on: db)
        }
    }
}

/// The MCP name for the shared scope, which `ToolContext` holds.
typealias MCPVersionCaptureScope = AssignmentVersionCaptureScope
