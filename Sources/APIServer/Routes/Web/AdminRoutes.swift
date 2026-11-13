// APIServer/Routes/Web/AdminRoutes.swift
//
// Admin-only routes for user management.
// Assignment publishing/open/close/delete have moved to AssignmentRoutes (instructor+).
// All routes here require admin role (enforced in routes.swift).
//
//   GET  /admin                              → AdminPage  (the admin Overview)
//   GET  /admin/users?page=N&q=…             → AdminUsersPage (one bounded page, #2829)
//   POST /admin/users/:id/role               → change a user's role
//   POST /admin/courses/:courseID/copy       → duplicate course (setups + assignments, no enrolments)

import Core
import Elementary
import Fluent
import Foundation
import SQLKit
import Vapor

struct AdminRoutes: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let admin = routes.grouped("admin")
        admin.get(use: dashboard)
        admin.get("users", use: usersPage)
        admin.get("users-data", use: usersData)
        admin.get("storage", use: storagePage)
        admin.get("runners", use: runners)
        admin.get("runners", ":runnerID", use: runnerDetail)
        admin.get("activity", use: activity)
        admin.post("users", ":userID", "role", use: changeRole)
        admin.post("runner-autostart", use: updateLocalRunnerAutoStart)
        admin.get("audit", use: auditPage)
        admin.get("retention", use: retentionPage)
        admin.get("alerts", use: alertsPage)
        admin.post("alerts", "config", use: updateAlertsConfig)
        admin.post("alerts", "test", use: sendTestAlert)
        admin.get("courses", "new", use: newCourseForm)
        admin.post("courses", use: createCourse)
        admin.get("courses", ":courseID", use: courseDetail)
        admin.post("courses", ":courseID", "edit", use: editCourse)
        admin.post("courses", ":courseID", "archive", use: toggleCourseArchive)
        admin.post("courses", ":courseID", "copy", use: copyCourse)
        admin.post("courses", ":courseID", "clone", use: cloneCourseForNewTerm)
        admin.post("courses", ":courseID", "delete", use: deleteCourse)
        admin.post("courses", ":courseID", "enrollment-mode", use: setEnrollmentMode)
        admin.post("courses", ":courseID", "ai-feedback", use: setCourseAIFeedback)
        admin.post("courses", ":courseID", "enroll-csv", use: adminBulkEnrollCSV)
        admin.post("courses", ":courseID", "unenroll", ":userID", use: unenrollUserFromCourse)
        admin.post("courses", ":courseID", "role", ":userID", use: adminSetEnrollmentRole)
        admin.post("courses", ":courseID", "staff", use: adminAddStaff)
        admin.get("users", ":userID", use: userDetail)
        admin.post("users", ":userID", "delete", use: deleteUser)
        admin.post("users", ":userID", "enroll", use: adminEnrollUser)
        admin.post("users", ":userID", "unenroll", ":courseID", use: adminUnenrollUser)
        admin.get("brightspace", use: brightspacePage)
        admin.post("brightspace", "authorize", use: brightspaceAuthorize)
        admin.get("brightspace", "valence-callback", use: brightspaceValenceCallback)
        admin.post("brightspace", "clear", use: brightspaceClearAuthorization)
        admin.post("brightspace", "set-credentials", use: brightspaceSetCredentials)
        admin.post("brightspace", "test", use: brightspaceTestConnection)
        admin.get("mcp", use: mcpPage)
        admin.post("mcp", "accounts", use: createMCPAccount)
        admin.post("mcp", "accounts", ":userID", "token", use: mintMCPToken)
        admin.post("mcp", "accounts", ":userID", "delete", use: deleteMCPAccount)
        admin.post("mcp", "accounts", ":userID", "enroll", use: enrollMCPAccount)
        admin.post("mcp", "accounts", ":userID", "unenroll", use: unenrollMCPAccount)
        admin.get("lti", use: ltiPage)
        admin.post("lti", "platforms", use: createLTIPlatform)
        admin.post("lti", "platforms", ":platformID", use: updateLTIPlatform)
        admin.post("lti", "platforms", ":platformID", "enabled", use: setLTIPlatformEnabled)
        admin.post("lti", "platforms", ":platformID", "delete", use: deleteLTIPlatform)
        admin.get("github", use: githubPage)
        admin.get("github", "callback", use: githubCallback)
        admin.post("github", "delete", use: deleteGitHubApp)
    }

    // MARK: - GET /admin

    @Sendable
    func dashboard(req: Request) async throws -> HTMLResponse<AdminPage> {
        let workerRows = try await makeWorkerRows(req: req)

        // Course management data — all three queries are independent so run in parallel.
        async let coursesFetch = APICourse.query(on: req.db).sort(\.$createdAt).all()
        async let enrollmentsFetch = enrolledStudentCountsByCourse(on: req.db)
        async let assignmentsFetch = assignmentCountsByCourse(on: req.db)
        let (allCourses, enrollmentCounts, assignmentCounts) =
            try await (coursesFetch, enrollmentsFetch, assignmentsFetch)
        // Submission counts need the (active) course IDs, so they run after the
        // course fetch resolves.
        let activeCourseIDs = allCourses.filter { !$0.isArchived }.compactMap(\.id)
        let submissionCounts = try await SubmissionRetentionService.submissionCountsByCourse(
            courseIDs: activeCourseIDs, on: req.db)
        let bsSyncEnabled = req.application.brightSpaceAppCredentials != nil
        // Archived courses move out of Overview and live on the Retention tab.
        let courseRows = allCourses.sorted {
            $0.code.localizedStandardCompare($1.code) == .orderedAscending
        }.compactMap { course -> AdminCourseRow? in
            guard let id = course.id, !course.isArchived else { return nil }
            return AdminCourseRow(
                id: id.uuidString,
                code: course.code,
                name: course.name,
                isArchived: course.isArchived,
                enrollmentMode: course.enrollmentMode.rawValue,
                enrollmentCount: enrollmentCounts[id] ?? 0,
                assignmentCount: assignmentCounts[id] ?? 0,
                submissionCount: submissionCounts[id] ?? 0,
                createdAt: course.createdAt.map { iso8601String($0) } ?? "—",
                brightspaceOrgUnitID: course.brightspaceOrgUnitID,
                brightspaceSyncEnabled: bsSyncEnabled
            ).withTerm(course.term)
        }

        // Default activity series (24h) so the chart renders server-side on
        // first paint; the client swaps windows / polls via GET /admin/activity.
        let activityChart = try await UserActivityChartService.chartData(
            window: .day, on: req.db)

        return HTMLResponse {
            AdminPage(
                page: PageRequestContext(request: req),
                workers: workerRows.map(AdminRunnerRow.init),
                courses: courseRows,
                activityChart: activityChart
            )
        }
    }

    // MARK: - GET /admin/activity

    /// JSON series for the "active users over time" chart.  `window` is one of
    /// `24h` / `1w` / `1m` (defaults to `24h`).  Polled by the dashboard with
    /// the `X-Background-Refresh` header so the viewing admin's own polls don't
    /// inflate the counts.
    @Sendable
    func activity(req: Request) async throws -> ActivityChartData {
        let window =
            (try? req.query.get(String.self, at: "window"))
            .flatMap(ActivityWindow.init(rawValue:)) ?? .day
        return try await UserActivityChartService.chartData(window: window, on: req.db)
    }

    // MARK: - GET /admin/users

    /// One bounded page of people (#2829): `?page=N`, 1-based.
    @Sendable
    func usersPage(req: Request) async throws -> HTMLResponse<AdminUsersPage> {
        let directory = try await AdminUserDirectory.page(
            requestedUsersPage(req) ?? 1, search: req.query[String.self, at: "q"], on: req.db)
        let userRows = try await pagedUserRows(directory, viewerID: req.auth.get(APIUser.self)?.id, on: req.db)
        return HTMLResponse {
            AdminUsersPage(
                page: PageRequestContext(request: req),
                users: userRows,
                userCount: directory.total,
                adminCount: directory.adminCount,
                pager: AdminUsersPager(directory)
            )
        }
    }

    // MARK: - GET /admin/users-data
    //
    // Feed backing the Users tab's auto-refresh poll. Polls send the
    // `X-Background-Refresh` header so they don't count as session activity
    // (see UserActivityMiddleware).

    /// Two representations: `?fragment=rows` renders `UserRows` — the SAME
    /// view the page renders, so the poll cannot drift from the page — for
    /// one bounded page (`?page=N`, default 1, and `?q=` to search, #2829).
    /// Anything else is the JSON array. With no `page` and no `q` it is every
    /// user, in the old order, as before, for other consumers. With either it
    /// is that one page (new in #2829).
    @Sendable
    func usersData(req: Request) async throws -> Response {
        let viewerID = req.auth.get(APIUser.self)?.id
        let wantsRows = req.query[String.self, at: "fragment"] == "rows"
        let requestedPage = requestedUsersPage(req)
        let search = AdminUserDirectory.normalizedSearch(req.query[String.self, at: "q"])
        if !wantsRows && requestedPage == nil && search == nil {
            return try await fetchAllUserRows(on: req.db, viewerID: viewerID).encodeResponse(for: req)
        }
        let directory = try await AdminUserDirectory.page(requestedPage ?? 1, search: search, on: req.db)
        let rows = try await pagedUserRows(directory, viewerID: viewerID, on: req.db)
        guard wantsRows else {
            return try await rows.encodeResponse(for: req)
        }
        let csrfToken = PageRequestContext(request: req).csrfToken
        let html = UserRows(users: rows, csrfToken: csrfToken).render()
        return Response.pollFragment(html: html, csrfToken: csrfToken, for: req)
    }

    /// The `page` query value, or nil when the request names none or one that
    /// is not a number.
    private func requestedUsersPage(_ req: Request) -> Int? {
        req.query[Int.self, at: "page"]
    }

    /// The rows for one bounded page. The staff set is read for this page's
    /// users only, so its `IN` list is at most one page long.
    private func pagedUserRows(
        _ directory: AdminUserDirectoryPage, viewerID: UUID?, on db: any Database
    ) async throws -> [AdminUserRow] {
        let staff = try await AvatarStore.courseStaff(among: directory.users.compactMap(\.id), on: db)
        return try await userRows(for: directory.users, staff: staff, viewerID: viewerID, on: db)
    }

    /// Loads every user, ordered most-recently-seen first (NULL last_seen
    /// rows sink to the bottom, then username, then join date), and maps
    /// them to the wire/template row shape. Only the unpaged JSON feed reads
    /// this; the page and its poll read `AdminUserDirectory.page`.
    private func fetchAllUserRows(on db: any Database, viewerID: UUID?) async throws -> [AdminUserRow] {
        let users = try await APIUser.query(on: db)
            .all()
            .sorted { lhs, rhs in
                switch (lhs.lastSeenAt, rhs.lastSeenAt) {
                case (let l?, let r?):
                    if l != r { return l > r }
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                case (nil, nil):
                    break
                }

                if lhs.username != rhs.username {
                    return lhs.username.localizedStandardCompare(rhs.username) == .orderedAscending
                }

                let lhsCreated = lhs.createdAt ?? .distantPast
                let rhsCreated = rhs.createdAt ?? .distantPast
                return lhsCreated < rhsCreated
            }

        // Every user is on this list, so the staff set is read whole rather
        // than through an IN list of every user ID (#2777).
        let staff = try await AvatarStore.allCourseStaff(on: db)
        return try await userRows(for: users, staff: staff, viewerID: viewerID, on: db)
    }

    /// Maps users to the wire/template row shape, in the order given.
    private func userRows(
        for users: [APIUser], staff: Set<UUID>, viewerID: UUID?, on db: any Database
    ) async throws -> [AdminUserRow] {
        // This list belongs to no one course, so the staff ring means "teaches
        // somewhere", as on the account page (docs/student-wardrobe.md).
        var rows: [AdminUserRow] = []
        for user in users {
            // Each person's own seeded bird, the one their account page shows.
            // A user seen here for the first time gets one written. An MCP
            // service account is not a person and never opens an account
            // page, so it gets no bird and no row written for one (#1764).
            var row = AdminUserRow(
                id: user.id?.uuidString ?? "",
                displayName: user.displayName,
                username: user.username,
                role: user.role,
                createdAt: user.createdAt.map { iso8601String($0) } ?? "—",
                lastSeenAt: user.lastSeenAt.map { iso8601String($0) },
                isCurrentUser: user.id != nil && user.id == viewerID)
            if user.roleValue != .mcp {
                row.avatar = try await AvatarStore.rosterAvatar(
                    for: user, isStaff: user.id.map(staff.contains) ?? false, on: db)
            }
            rows.append(row)
        }
        return rows
    }

    // MARK: - GET /admin/storage

    @Sendable
    func storagePage(req: Request) async throws -> HTMLResponse<AdminStoragePage> {
        let storage = try await StorageUsage.context(app: req.application)
        return HTMLResponse {
            AdminStoragePage(
                page: PageRequestContext(request: req),
                storage: storage,
                assignmentRows: AdminStorageShareRow.rows(
                    from: storage.assignments, totalBytes: storage.totalBytes))
        }
    }

    // MARK: - POST /admin/users/:id/role

    @Sendable
    func changeRole(req: Request) async throws -> Response {
        struct RoleBody: Content { var role: String }

        guard
            let idString = req.parameters.get("userID"),
            let uuid = UUID(uuidString: idString),
            let user = try await APIUser.find(uuid, on: req.db)
        else {
            throw AppError.notFound(resource: "User account")
        }

        // An admin who demotes themselves may leave no way back. Another admin
        // must make the change, so at least one admin always remains.
        if try req.auth.require(APIUser.self).id == uuid {
            throw AppError.forbidden(action: "change your own role")
        }

        let body = try await req.decodeContent(RoleBody.self)
        // The deployment role is user|admin now (#417 Slice G2); `mcp` is set only
        // at agent provisioning, never toggled here, and the retired
        // student/instructor roles are no longer assignable.
        guard [UserRole.user.rawValue, UserRole.admin.rawValue].contains(body.role) else {
            throw AppError.invalidParameter(
                name: "role",
                reason: "must be user or admin (got '\(body.role)')")
        }

        let previousRole = user.role
        user.role = body.role
        try await user.save(on: req.db)
        await AuditLogger.record(
            action: .userRoleChanged,
            targetType: .user,
            targetID: idString,
            metadata: [
                "subject_username": user.username,
                "previous_role": previousRole,
                "new_role": body.role,
            ],
            on: req
        )
        return req.redirect(to: "/admin/users")
    }

    // MARK: - POST /admin/runner-autostart

    @Sendable
    func updateLocalRunnerAutoStart(req: Request) async throws -> Response {
        struct AutoStartBody: Content {
            var localRunnerAutoStart: String?
        }

        let body = try await req.decodeContent(AutoStartBody.self)
        let enabled = (body.localRunnerAutoStart == "on")
        await req.application.localRunnerAutoStartStore.setEnabled(enabled)
        writeLocalRunnerAutoStartToDisk(
            enabled: enabled,
            filePath: req.application.localRunnerAutoStartFilePath
        )
        req.logger.info("Admin updated local runner autostart setting: \(enabled)")
        await AuditLogger.record(
            action: .runnerAutostartChanged,
            targetType: .runner,
            metadata: ["enabled": enabled ? "true" : "false"],
            on: req
        )
        return req.redirect(to: "/admin")
    }

    // MARK: - GET /admin/alerts

    @Sendable
    func alertsPage(req: Request) async throws -> HTMLResponse<AlertsPage> {
        struct FlashQuery: Content {
            var ok: String?
            var error: String?
        }
        let query = (try? req.query.decode(FlashQuery.self)) ?? FlashQuery()

        let configuration = req.application.serverHealthAlertConfiguration
        let monitor = req.application.serverHealthAlertMonitor
        let effectiveURL = await monitor.effectiveWebhookURL() ?? ""
        let envURL = configuration.webhookURLFromEnvironment ?? ""
        let states = await monitor.currentRuleStates()
        let recent = await monitor.recentFiringsSnapshot()

        let ruleRows = HealthRule.allCases.map { rule -> AdminAlertsRuleRow in
            let state = states[rule] ?? .initial
            return AdminAlertsRuleRow(
                rule: rule.rawValue,
                humanReadable: rule.humanReadable,
                isFiring: state.isFiring,
                lastFiredAt: state.lastFiredAt.map { iso8601String($0) },
                thresholdText: rule.thresholdText(configuration)
            )
        }

        let firingRows = recent.map(AdminAlertFiringRow.init)
        let lastDelivery = AdminAlertsPresentation.lastDelivery(firingRows, records: recent)
        return HTMLResponse {
            AlertsPage(
                page: PageRequestContext(request: req),
                flash: FlashMessages(success: query.ok, error: query.error),
                enabled: configuration.enabled,
                webhookURL: effectiveURL,
                webhookURLFromEnvironment: !envURL.isEmpty,
                rules: ruleRows,
                webhookDisplay: AdminAlertsPresentation.webhookDisplay(effectiveURL),
                lastDelivery: lastDelivery,
                firingDays: DayGrouper.group(firingRows, occurredAt: \.occurredAt)
            )
        }
    }

    // MARK: - POST /admin/alerts/config

    @Sendable
    func updateAlertsConfig(req: Request) async throws -> Response {
        struct AlertsConfigBody: Content { var webhookURL: String? }
        let body = try await req.decodeContent(AlertsConfigBody.self)
        let trimmed = (body.webhookURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmed.isEmpty {
            guard let parsed = URL(string: trimmed),
                let scheme = parsed.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else {
                return req.redirect(
                    to: adminNoticeRedirect("/admin/alerts", error: "Webhook URL must start with http:// or https://"))
            }
        }

        await req.application.serverHealthAlertMonitor.setWebhookURL(trimmed)
        req.logger.info("Admin updated alerts webhook URL (\(trimmed.isEmpty ? "cleared" : "set"))")
        return req.redirect(
            to: adminNoticeRedirect("/admin/alerts", ok: trimmed.isEmpty ? "Webhook cleared." : "Webhook saved."))
    }

    // MARK: - POST /admin/alerts/test

    @Sendable
    func sendTestAlert(req: Request) async throws -> Response {
        let monitor = req.application.serverHealthAlertMonitor
        let effectiveURL = await monitor.effectiveWebhookURL() ?? ""

        if effectiveURL.isEmpty {
            return req.redirect(
                to: adminNoticeRedirect("/admin/alerts", error: "No webhook URL configured. Set one above first."))
        }

        do {
            _ = try await monitor.dispatchTestAlert(application: req.application)
            return req.redirect(to: adminNoticeRedirect("/admin/alerts", ok: "Test alert dispatched to webhook."))
        } catch {
            req.logger.warning("Test alert dispatch failed: \(error)")
            return req.redirect(
                to: adminNoticeRedirect(
                    "/admin/alerts", error: "The test alert was not delivered. Check the webhook URL and try again."))
        }
    }

    // MARK: - GET /admin/users/:userID

    @Sendable
    func userDetail(req: Request) async throws -> HTMLResponse<AdminUserPage> {
        guard
            let idString = req.parameters.get("userID"),
            let userID = UUID(uuidString: idString),
            let user = try await APIUser.find(userID, on: req.db)
        else {
            throw AppError.notFound(resource: "User account")
        }

        let allCourses = try await APICourse.query(on: req.db)
            .filter(\.$isArchived == false)
            .all()
            .sorted(by: courseListPrecedes)

        let enrollments = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$userID == userID)
            .with(\.$course)
            .all()

        let enrolledIDs = Set(enrollments.map(\.$course.id))

        let enrolledRows =
            enrollments
            .map(\.course)
            .sorted(by: courseListPrecedes)
            .compactMap { course -> AdminCourseRef? in
                guard let id = course.id else { return nil }
                return AdminCourseRef(
                    id: id.uuidString, code: course.code, name: course.name, termLabel: course.term?.displayName)
            }

        let availableRows = allCourses.compactMap { c -> AdminCourseRef? in
            guard let id = c.id, !enrolledIDs.contains(id) else { return nil }
            return AdminCourseRef(id: id.uuidString, code: c.code, name: c.name, termLabel: c.term?.displayName)
        }

        return HTMLResponse {
            AdminUserPage(
                page: PageRequestContext(request: req),
                flash: FlashMessages(
                    error: req.query[String.self, at: "error"].flatMap(AdminEnrollError.init(rawValue:))?.message),
                targetUserID: idString,
                displayName: user.displayName,
                username: user.username,
                role: user.role,
                enrolledCourses: enrolledRows,
                availableCourses: availableRows
            )
        }
    }

    // MARK: - POST /admin/users/:userID/delete

    @Sendable
    func deleteUser(req: Request) async throws -> Response {
        guard
            let idString = req.parameters.get("userID"),
            let uuid = UUID(uuidString: idString),
            let user = try await APIUser.find(uuid, on: req.db)
        else {
            throw AppError.notFound(resource: "User account")
        }

        let deletedUsername = user.username
        let deletedRole = user.role

        // The columns that name a user with NO foreign key are cleared here,
        // before the row goes (docs/operational-diagnostics.md "User-row
        // foreign-key cascade"). Every other reference is a declared FK.
        // `UserReferenceScanTests` lists the FK-less
        // columns, so a new one must be cleared here or kept on purpose there
        // (#1808).
        //
        // `class_achievements.user_id` and `submissions.retested_by_user_id`
        // gained their FKs late (`AddUserFKConstraints`), and the cleanup from
        // before that, when SQLite could not add them, agrees with them.
        try await APIClassAchievement.query(on: req.db)
            .filter(\.$userID == uuid)
            .delete()
        try await APISubmission.query(on: req.db)
            .filter(\.$retestedByUserID == uuid)
            .set(\.$retestedByUserID, to: nil)
            .update()
        // A tournament run is history and stays; who started it and who won
        // it drop, as the retest attribution does.
        try await APITournamentRun.query(on: req.db)
            .filter(\.$startedBy == uuid)
            .set(\.$startedBy, to: nil)
            .update()
        try await APITournamentRun.query(on: req.db)
            .filter(\.$winnerUserID == uuid)
            .set(\.$winnerUserID, to: nil)
            .update()
        // A class composite's spare job holds a copy of the student's code
        // but no user ID (docs/class-composite.md), so the cascade from the
        // user would leave it. It goes, with its files.
        let courseSpareJobIDs = try await APICompositeSpare.query(on: req.db)
            .filter(\.$userID == uuid).all().map(\.submissionID)
        let groupSpareJobIDs = try await APIGroupCompositeSpare.query(on: req.db)
            .filter(\.$userID == uuid).all().map(\.submissionID)
        let spareJobIDs = courseSpareJobIDs + groupSpareJobIDs
        let spareJobs =
            spareJobIDs.isEmpty ? [] : try await APISubmission.query(on: req.db).filter(\.$id ~~ spareJobIDs).all()
        for job in spareJobs {
            try await job.delete(on: req.db)
            try? FileManager.default.removeItem(atPath: job.zipPath)
            try? FileManager.default.removeItem(atPath: job.zipPath + ".grading")
        }

        try await user.delete(on: req.db)
        await AuditLogger.record(
            action: .userDeleted,
            targetType: .user,
            targetID: idString,
            metadata: [
                "subject_username": deletedUsername,
                "subject_role": deletedRole,
            ],
            on: req
        )
        return req.redirect(to: "/admin")
    }

}

/// An admin page's path with its one-shot `ok` or `error` notice in the query
/// (#2492: the alerts and retention pages each had a copy of this).
func adminNoticeRedirect(_ path: String, ok: String? = nil, error: String? = nil) -> String {
    var pairs: [String] = []
    if let okValue = ok?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
        pairs.append("ok=\(okValue)")
    }
    if let errorValue = error?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
        pairs.append("error=\(errorValue)")
    }
    return pairs.isEmpty ? path : path + "?" + pairs.joined(separator: "&")
}

func assignmentCountsByCourse(on db: any Database) async throws -> [UUID: Int] {
    // DB-side grouped COUNT rather than loading every assignment row into
    // memory and tallying in Swift. Falls back to the in-memory tally on the
    // (currently nonexistent) non-SQL driver.
    guard let sql = db as? (any SQLDatabase) else {
        let assignments = try await APIAssignment.query(on: db).all()
        return assignments.reduce(into: [:]) { $0[$1.courseID, default: 0] += 1 }
    }

    let rows = try await sql.select()
        .column("course_id")
        .column(SQLFunction("COUNT", args: SQLLiteral.all), as: "total")
        .from("assignments")
        .groupBy("course_id")
        .all(decoding: CourseAssignmentCountRow.self)
    return rows.reduce(into: [:]) { $0[$1.courseID] = $1.total }
}

private struct CourseAssignmentCountRow: Decodable {
    let courseID: UUID
    let total: Int

    enum CodingKeys: String, CodingKey {
        case courseID = "course_id"
        case total
    }
}
