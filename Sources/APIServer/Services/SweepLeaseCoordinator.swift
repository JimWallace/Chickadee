// APIServer/Services/SweepLeaseCoordinator.swift
//
// Leader election for periodic sweeps (#1155). Every server process runs
// every PeriodicSweepMonitor loop; the lease decides which process actually
// executes each sweep body. Claiming is a compare-and-set in the same family
// as the worker-job claim and the MCP token consumption:
//
//   1. Conditional UPDATE: take/renew the row when we already hold it OR it
//      has expired. A single UPDATE statement is atomic on SQLite and
//      Postgres alike, so two instances can't both succeed for the same
//      window.
//   2. Verify by re-read: whoever's holder id is on the row owns the lease.
//   3. First-ever claim: PRIMARY KEY insert; a unique violation means the
//      other instance won — verified by the same re-read.
//
// Single-process deployments trivially always hold every lease — the cost
// is one tiny UPDATE + SELECT per sweep tick.

import Fluent
import Foundation
import Vapor

enum SweepLeaseCoordinator {
    /// Claims or renews the lease for `name` on behalf of `holder`.
    /// Returns true when `holder` owns the lease for the next `ttlSeconds`.
    static func acquireOrRenew(
        name: String,
        holder: String,
        ttlSeconds: TimeInterval,
        now: Date = Date(),
        on db: Database
    ) async throws -> Bool {
        let newExpiry = now.addingTimeInterval(ttlSeconds)

        // Renew our own lease, or take over an expired one — atomically.
        try await SweepLease.query(on: db)
            .filter(\.$id == name)
            .group(.or) { or in
                or.filter(\.$holder == holder)
                or.filter(\.$expiresAt <= now)
            }
            .set(\.$holder, to: holder)
            .set(\.$expiresAt, to: newExpiry)
            .update()

        if let row = try await SweepLease.find(name, on: db) {
            return row.holder == holder && row.expiresAt > now
        }

        // No row yet: first claim ever for this sweep name.
        do {
            try await SweepLease(name: name, holder: holder, expiresAt: newExpiry).create(on: db)
            return true
        } catch {
            // Lost the insert race to another instance — re-read decides.
            if let row = try await SweepLease.find(name, on: db) {
                return row.holder == holder && row.expiresAt > now
            }
            throw error
        }
    }
}

// MARK: - Per-process holder identity

struct SweepLeaseHolderIDKey: StorageKey {
    typealias Value = String
}

extension Application {
    /// Stable per-process (per-Application) identity used as the lease
    /// holder. Random per boot: a restarted process is a new holder and
    /// simply takes over its old leases as they expire (or immediately,
    /// since the old process stopped renewing).
    var sweepLeaseHolderID: String {
        if let existing = storage[SweepLeaseHolderIDKey.self] { return existing }
        let created = UUID().uuidString
        storage[SweepLeaseHolderIDKey.self] = created
        return created
    }
}
