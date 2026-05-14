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
        let actor = actorOverride ?? req.auth.get(APIUser.self)
        let actorUserID = actor?.id
        let actorUsername = actorUsernameOverride ?? actor?.username

        let trust = req.application.securityConfiguration.trustForwardedProto
        let remoteAddr = clientIPAddress(from: req, trustForwardedFor: trust)
        let userAgent = req.headers.first(name: "User-Agent")
        let metadataJSON = metadata.flatMap(encodeMetadata)

        let entry = APIAuditLogEntry(
            actorUserID: actorUserID,
            actorUsername: actorUsername,
            action: action.rawValue,
            targetType: targetType?.rawValue,
            targetID: targetID,
            remoteAddr: remoteAddr,
            userAgent: userAgent,
            metadata: metadataJSON
        )
        do {
            try await entry.save(on: req.db)
        } catch {
            req.logger.error(
                "audit_log write failed for action=\(action.rawValue): \(error.localizedDescription)"
            )
        }
    }

    private static func encodeMetadata(_ dict: [String: String]) -> String? {
        guard !dict.isEmpty else { return nil }
        let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }
}
