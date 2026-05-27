// APIServer/Routes/Web/AdminRoutes+Retention.swift
//
// Admin "Retention" tab: a report-first view of archived courses (FIPPA /
// UWaterloo TL55 retention — student submissions are personal information
// kept one year after the end of term, signalled here by archiving).  Lists
// every archived course with its archival date and the date it becomes
// eligible for permanent deletion.  Each row can be Restored (unarchived) at
// any time; once the retention window has elapsed it can also be permanently
// Deleted.  Nothing here deletes automatically.
//
// The Restore and Delete actions reuse the course endpoints registered in
// AdminRoutes.boot() (`/archive` toggle and `/delete`).

import Core
import Fluent
import Foundation
import Vapor

extension AdminRoutes {
    // MARK: - GET /admin/retention

    @Sendable
    func retentionPage(req: Request) async throws -> View {
        struct FlashQuery: Content {
            var ok: String?
            var error: String?
        }
        let flash = (try? req.query.decode(FlashQuery.self)) ?? FlashQuery()
        let retentionDays = req.application.appConfig.diagnostics.submissionRetentionDays

        // Load all courses and filter archived in Swift — matches the admin
        // dashboard's approach (course count is admin-scale) and keeps the
        // listing backend-agnostic.
        let archivedCourses = try await APICourse.query(on: req.db)
            .all()
            .filter { $0.isArchived }
        let courseIDs = archivedCourses.compactMap { $0.id }
        let counts = try await SubmissionRetentionService.submissionCountsByCourse(
            courseIDs: courseIDs, on: req.db)

        let now = Date()
        let df = waterlooDateTimeFormatter()
        let iso = ISO8601DateFormatter()

        // Build (course, status) pairs so we can sort by delete-eligibility
        // before mapping to the formatted row shape.
        struct Entry {
            let course: APICourse
            let archivedAt: Date?
            let eligibleAt: Date?
            let isDeletable: Bool
            let count: Int
        }
        let entries: [Entry] = archivedCourses.compactMap { course in
            guard let id = course.id else { return nil }
            let count = counts[id] ?? 0
            guard let archivedAt = course.archivedAt else {
                return Entry(
                    course: course, archivedAt: nil, eligibleAt: nil,
                    isDeletable: false, count: count)
            }
            let eligibleAt = SubmissionRetentionService.purgeEligibleDate(
                archivedAt: archivedAt, retentionDays: retentionDays)
            return Entry(
                course: course, archivedAt: archivedAt, eligibleAt: eligibleAt,
                isDeletable: now >= eligibleAt, count: count)
        }
        .sorted { lhs, rhs in
            // Delete-eligible courses first, then soonest-eligible, then by code.
            if lhs.isDeletable != rhs.isDeletable { return lhs.isDeletable }
            switch (lhs.eligibleAt, rhs.eligibleAt) {
            case (let l?, let r?) where l != r: return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            default: return lhs.course.code < rhs.course.code
            }
        }

        let rows = entries.compactMap { entry -> AdminRetentionRow? in
            guard let id = entry.course.id else { return nil }
            return AdminRetentionRow(
                id: id.uuidString,
                code: entry.course.code,
                name: entry.course.name,
                archivedAt: entry.archivedAt.map { df.string(from: $0) } ?? "—",
                archivedAtISO: entry.archivedAt.map { iso.string(from: $0) } ?? "",
                purgeEligibleAt: entry.eligibleAt.map { df.string(from: $0) } ?? "—",
                purgeEligibleAtISO: entry.eligibleAt.map { iso.string(from: $0) } ?? "",
                submissionCount: entry.count,
                isDeletable: entry.isDeletable
            )
        }

        let ctx = AdminRetentionContext(
            currentUser: req.currentUserContext,
            activeAdminTab: "retention",
            retentionDays: retentionDays,
            rows: rows,
            deletableCount: rows.filter { $0.isDeletable }.count,
            flashSuccess: flash.ok,
            flashError: flash.error
        )
        return try await req.view.render("admin-retention", ctx)
    }
}

func retentionRedirect(ok: String? = nil, error: String? = nil) -> String {
    var pairs: [String] = []
    if let okValue = ok?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
        pairs.append("ok=\(okValue)")
    }
    if let errorValue = error?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
        pairs.append("error=\(errorValue)")
    }
    return pairs.isEmpty ? "/admin/retention" : "/admin/retention?" + pairs.joined(separator: "&")
}
