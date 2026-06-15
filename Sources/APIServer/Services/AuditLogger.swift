// APIServer/Services/AuditLogger.swift
//
// Single chokepoint for writing structured audit records.  Centralising the
// write keeps the call sites in route handlers compact, and means the
// remote-address / user-agent extraction follows one consistent set of
// trust rules.
//
// All methods swallow their own errors after logging — an audit-log write
// failure must never block the primary action (e.g. a user-delete handler
// is still allowed to delete the user even if the audit row can't be
// persisted).  The error path is logged with `req.logger.error`.

import Fluent
import Foundation
import Vapor

enum AuditLogger {
    /// Records an audit entry against the current request.  The actor is
    /// inferred from the session-authenticated user (nil for unauthenticated
    /// events such as failed logins).
    static func record(
        action: AuditAction,
        targetType: AuditTargetType? = nil,
        targetID: String? = nil,
        metadata: [String: String]? = nil,
        actorOverride: APIUser? = nil,
        actorUsernameOverride: String? = nil,
        on req: Request
    ) async {
        _ = await recordReturning(
            action: action, targetType: targetType, targetID: targetID, metadata: metadata,
            actorOverride: actorOverride, actorUsernameOverride: actorUsernameOverride, on: req)
    }

    /// Like `record`, but returns the persisted entry — or nil when the write
    /// failed — so a caller can fail closed on a missing audit record (e.g. an
    /// MCP write tool that must not mutate state unrecorded) or stamp later
    /// fields onto the same row.  The failure is still logged.
    static func recordReturning(
        action: AuditAction,
        targetType: AuditTargetType? = nil,
        targetID: String? = nil,
        metadata: [String: String]? = nil,
        actorOverride: APIUser? = nil,
        actorUsernameOverride: String? = nil,
        on req: Request
    ) async -> APIAuditLogEntry? {
        let actor = actorOverride ?? req.auth.get(APIUser.self)
        let trust = req.application.securityConfiguration.trustForwardedProto

        let entry = APIAuditLogEntry(
            actorUserID: actor?.id,
            actorUsername: actorUsernameOverride ?? actor?.username,
            action: action.rawValue,
            targetType: targetType?.rawValue,
            targetID: targetID,
            remoteAddr: clientIPAddress(from: req, trustForwardedFor: trust),
            userAgent: req.headers.first(name: "User-Agent"),
            metadata: metadata.flatMap(encodeMetadata)
        )
        do {
            try await entry.save(on: req.db)
            return entry
        } catch {
            req.logger.error(
                "audit_log write failed for action=\(action.rawValue): \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Best-effort: merges `extra` into an already-persisted entry's metadata and
    /// saves it.  Used to stamp a final field (e.g. the call outcome) onto a row
    /// written before the action ran.  A failure here is non-critical — the
    /// durable record already exists — so it is logged, not propagated.
    static func updateMetadata(
        _ entry: APIAuditLogEntry, merging extra: [String: String], on req: Request
    ) async {
        var dict = entry.metadata.flatMap(decodeMetadata) ?? [:]
        for (key, value) in extra { dict[key] = value }
        entry.metadata = encodeMetadata(dict)
        do {
            try await entry.update(on: req.db)
        } catch {
            req.logger.error("audit_log metadata update failed: \(error.localizedDescription)")
        }
    }

    private static func encodeMetadata(_ dict: [String: String]) -> String? {
        guard !dict.isEmpty else { return nil }
        let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func decodeMetadata(_ json: String) -> [String: String]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }
}
