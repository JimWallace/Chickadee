// APIServer/Routes/Web/AdminRoutes+Audit.swift
//
// Admin "Audit Log" tab: a filterable, human-readable view of the security and
// admin audit trail (`APIAuditLogEntry`).  Each row carries a coarse category
// and a plain-language label resolved from the stored action identifier, so the
// most recent 200 matching entries stay legible even as high-volume events
// (MCP tool calls, logins) accumulate.  Filters narrow by action and actor.

import Fluent
import Foundation
import Vapor

extension AdminRoutes {
    // MARK: - GET /admin/audit

    @Sendable
    func auditPage(req: Request) async throws -> View {
        struct AuditFilterQuery: Content {
            var action: String?
            var actor: String?
        }
        let filter = (try? req.query.decode(AuditFilterQuery.self)) ?? AuditFilterQuery()
        func trimmedOrNil(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespaces) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        let filterAction = trimmedOrNil(filter.action)
        let filterActor = trimmedOrNil(filter.actor)

        // Build the filtered query once, count it, then take the most recent 200.
        func base() -> QueryBuilder<APIAuditLogEntry> {
            let query = APIAuditLogEntry.query(on: req.db)
            if let filterAction {
                query.filter(\.$action == filterAction)
            }
            if let filterActor {
                query.filter(\.$actorUsername ~~ filterActor)
            }
            return query
        }
        let matchCount = try await base().count()
        let entries = try await base()
            .sort(\.$createdAt, .descending)
            .limit(200)
            .all()

        let timestampFormatter = waterlooDateTimeFormatter()
        let isoFormatter = ISO8601DateFormatter()
        let rows = entries.map { entry -> AdminAuditRow in
            let display = AuditActionDisplay.categoryLabel(forRaw: entry.action)
            let outcome = AuditActionDisplay.outcome(forRaw: entry.action)
            return AdminAuditRow(
                timestamp: entry.createdAt.map { timestampFormatter.string(from: $0) } ?? "—",
                timestampISO: entry.createdAt.map { isoFormatter.string(from: $0) } ?? "",
                actor: entry.actorUsername ?? "—",
                category: display.category,
                label: display.label,
                action: entry.action,
                targetType: entry.targetType,
                targetID: entry.targetID,
                metadata: entry.metadata ?? "",
                remoteAddr: entry.remoteAddr ?? "—",
                outcome: outcome.rawValue,
                outcomeTier: outcome.tierClass
            )
        }

        // Action dropdown: grouped "Category — Label", sorted, with the current
        // selection marked.  Driven by the enum so it can't drift from reality.
        let actionOptions =
            AuditAction.allCases
            .map { action in
                AdminAuditFilterOption(
                    value: action.rawValue,
                    label: "\(action.category.rawValue) — \(action.label)",
                    selected: action.rawValue == filterAction)
            }
            .sorted { $0.label < $1.label }

        return try await req.view.render(
            "admin-audit",
            AdminAuditContext(
                currentUser: req.currentUserContext,
                activeAdminTab: "audit",
                rows: rows,
                actionOptions: actionOptions,
                filterActor: filterActor ?? "",
                filtered: filterAction != nil || filterActor != nil,
                matchCount: matchCount)
        )
    }
}
