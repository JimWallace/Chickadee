// APIServer/LTI/LTIRecordReaper.swift
//
// Hourly cleanup of the LTI single-use rows (docs/lti-1-3.md "Launch" and
// "Deep Linking"). `/lti/login` writes one `lti_login_states` row per
// unauthenticated hit, and the deep-linking launch writes one
// `lti_deep_link_requests` row per picker open. Each row is consumed at most
// once and is dead the moment it expires or is consumed, but nothing in the
// flow deletes it, so a crawler or a misconfigured LMS grows both tables
// without bound.
//
// The MCP OAuth reaper does the same job for the OAuth rows. This is a
// separate monitor because that one runs only when MCP is mounted, and these
// rows exist on every deployment.

import Fluent
import Foundation
import Vapor

/// Hourly: dead rows are space hygiene, not correctness.
private let ltiRecordReaperInterval: TimeInterval = 3600

/// Deletes login states and deep-link requests that have expired or been
/// consumed. A consumed row can never be used again (the atomic burn blocks
/// it), so there is no reason to keep it until its lifetime lapses.
///
/// Two deletes per table, not one `expires_at < now OR consumed`: no index
/// covers `consumed`, so the OR scanned the whole table. Each delete here is
/// a range on the `expires_at` index (#1804). The second range holds only
/// live rows, which last at most 30 minutes (#2279).
func reapExpiredLTIRecords(on db: Database, logger: Logger, now: Date = Date()) async throws {
    try await APILTILoginState.query(on: db)
        .filter(\.$expiresAt < now)
        .delete()
    try await APILTILoginState.query(on: db)
        .filter(\.$expiresAt >= now)
        .filter(\.$consumed == true)
        .delete()
    try await APILTIDeepLinkRequest.query(on: db)
        .filter(\.$expiresAt < now)
        .delete()
    try await APILTIDeepLinkRequest.query(on: db)
        .filter(\.$expiresAt >= now)
        .filter(\.$consumed == true)
        .delete()
    logger.debug("LTI record reaper sweep complete")
}

private struct LTIRecordReaperMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    var ltiRecordReaperMonitor: PeriodicSweepMonitor {
        lazyStored(LTIRecordReaperMonitorKey.self) {
            PeriodicSweepMonitor(
                name: "LTI record reaper", interval: ltiRecordReaperInterval
            ) { application in
                try await reapExpiredLTIRecords(on: application.db, logger: application.logger)
            }
        }
    }
}
