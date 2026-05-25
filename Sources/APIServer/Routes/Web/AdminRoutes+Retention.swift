// APIServer/Routes/Web/AdminRoutes+Retention.swift
//
// Admin "Retention" tab: a report-first view of the submission-retention
// policy (student submissions purged one year after a course is archived,
// per FIPPA / UWaterloo TL55).  Lists every archived course with its
// archival date, the date its submissions become purgeable, and a manual
// Purge action that only the admin can trigger and only once the retention
// window has elapsed.  Nothing here deletes automatically.
//
// Routes are registered in AdminRoutes.boot().

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

        // Build (course, status) pairs so we can sort by purgeability before
        // mapping to the formatted row shape.
        struct Entry {
            let course: APICourse
            let archivedAt: Date?
            let eligibleAt: Date?
            let isPurgeable: Bool
            let count: Int
        }
        let entries: [Entry] = archivedCourses.compactMap { course in
            guard let id = course.id else { return nil }
            let count = counts[id] ?? 0
            guard let archivedAt = course.archivedAt else {
                return Entry(
                    course: course, archivedAt: nil, eligibleAt: nil,
                    isPurgeable: false, count: count)
            }
            let eligibleAt = SubmissionRetentionService.purgeEligibleDate(
                archivedAt: archivedAt, retentionDays: retentionDays)
            return Entry(
                course: course, archivedAt: archivedAt, eligibleAt: eligibleAt,
                isPurgeable: now >= eligibleAt, count: count)
        }
        .sorted { lhs, rhs in
            // Purgeable courses first, then soonest-eligible, then by code.
            if lhs.isPurgeable != rhs.isPurgeable { return lhs.isPurgeable }
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
                purgeEligibleAt: entry.eligibleAt.map { df.string(from: $0) } ?? "—",
                submissionCount: entry.count,
                isPurgeable: entry.isPurgeable
            )
        }

        let ctx = AdminRetentionContext(
            currentUser: req.currentUserContext,
            activeAdminTab: "retention",
            retentionDays: retentionDays,
            rows: rows,
            purgeableCount: rows.filter { $0.isPurgeable }.count,
            flashSuccess: flash.ok,
            flashError: flash.error
        )
        return try await req.view.render("admin-retention", ctx)
    }

    // MARK: - POST /admin/courses/:courseID/purge-submissions

    @Sendable
    func purgeCourseSubmissions(req: Request) async throws -> Response {
        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString),
            let course = try await APICourse.find(courseID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let retentionDays = req.application.appConfig.diagnostics.submissionRetentionDays

        // Server-side eligibility guard. Never trust the page that posted
        // here: a purge is only honoured for an archived course whose
        // retention window has actually elapsed.
        guard course.isArchived, let archivedAt = course.archivedAt else {
            return req.redirect(
                to: retentionRedirect(error: "\(course.code) is not archived — cannot purge."))
        }
        let eligibleAt = SubmissionRetentionService.purgeEligibleDate(
            archivedAt: archivedAt, retentionDays: retentionDays)
        guard Date() >= eligibleAt else {
            return req.redirect(
                to: retentionRedirect(
                    error: "\(course.code) is not yet past its retention window."))
        }

        let deleted = try await SubmissionRetentionService.purgeSubmissions(
            forCourseID: courseID, on: req.db)
        req.logger.info(
            "Admin purged \(deleted) submission(s) for archived course \(course.code) (\(idString)) under retention policy"
        )
        await AuditLogger.record(
            action: .submissionsPurged,
            targetType: .course,
            targetID: idString,
            metadata: [
                "course_code": course.code,
                "submissions_deleted": String(deleted),
                "retention_days": String(retentionDays),
            ],
            on: req
        )
        return req.redirect(
            to: retentionRedirect(ok: "Purged \(deleted) submission(s) for \(course.code)."))
    }
}

private func retentionRedirect(ok: String? = nil, error: String? = nil) -> String {
    var pairs: [String] = []
    if let okValue = ok?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
        pairs.append("ok=\(okValue)")
    }
    if let errorValue = error?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
        pairs.append("error=\(errorValue)")
    }
    return pairs.isEmpty ? "/admin/retention" : "/admin/retention?" + pairs.joined(separator: "&")
}
