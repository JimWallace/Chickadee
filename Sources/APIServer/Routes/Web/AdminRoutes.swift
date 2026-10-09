// APIServer/Routes/Web/AdminRoutes.swift
//
// Admin-only routes for user management.
// Assignment publishing/open/close/delete have moved to AssignmentRoutes (instructor+).
// All routes here require admin role (enforced in routes.swift).
//
//   GET  /admin                              → admin.leaf  (user management dashboard)
//   POST /admin/users/:id/role               → change a user's role
//   POST /admin/courses/:courseID/copy       → duplicate course (setups + assignments, no enrolments)

import Core
import Fluent
import Foundation
import SQLKit
import Vapor

struct AdminRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
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
    func dashboard(req: Request) async throws -> View {
        let workerRows = try await makeWorkerRows(req: req)

        // Course management data — all three queries are independent so run in parallel.
        async let coursesFetch = APICourse.query(on: req.db).sort(\.$createdAt).all()
        async let enrollmentsFetch = enrolledStudentCountsByCourse(on: req.db)
        async let assignmentsFetch = assignmentCountsByCourse(on: req.db)
        let (allCourses, enrollmentCounts, assignmentCounts) =
            try await (coursesFetch, enrollmentsFetch, assignmentsFetch)
        // Submission counts need the (active) course IDs, so they run after the
        // course fetch resolves.
        let activeCourseIDs = allCourses.filter { !$0.isArchived }.compactMap { $0.id }
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

        let ctx = AdminContext(
            currentUser: req.currentUserContext,
            activeAdminTab: "overview",
            workers: workerRows.map(AdminRunnerRow.init),
            courses: courseRows,
            version: ChickadeeVersion.current,
            activityChart: activityChart
        )
        return try await req.view.render("admin", ctx)
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

    @Sendable
    func usersPage(req: Request) async throws -> View {
        let userRows = try await fetchUserRows(on: req.db, viewerID: req.auth.get(APIUser.self)?.id)
        let ctx = AdminUsersContext(
            currentUser: req.currentUserContext,
            activeAdminTab: "users",
            users: userRows,
            userCount: userRows.count,
            adminCount: userRows.filter { $0.role == UserRole.admin.rawValue }.count
        )
        return try await req.view.render("admin-users", ctx)
    }

    // MARK: - GET /admin/users-data
    //
    // JSON feed backing the Users tab's auto-refresh poll.  Returns the same
    // rows `usersPage` renders so the client can repaint the table in place.
    // Polls send the `X-Background-Refresh` header so they don't count as
    // session activity (see UserActivityMiddleware).

    /// Two representations, one query: `?fragment=rows` renders
    /// `_user-rows.leaf` — the SAME partial the page renders, so the poll
    /// cannot drift from the page — and anything else keeps the JSON array
    /// unchanged for other consumers.
    @Sendable
    func usersData(req: Request) async throws -> Response {
        let rows = try await fetchUserRows(on: req.db, viewerID: req.auth.get(APIUser.self)?.id)
        guard req.query[String.self, at: "fragment"] == "rows" else {
            return try await rows.encodeResponse(for: req)
        }
        return try await req.view.render("_user-rows", UserRowsFragmentContext(users: rows))
            .encodePollFragment(for: req)
    }

    /// Loads every user, ordered most-recently-seen first (NULL last_seen
    /// rows sink to the bottom, then username, then join date), and maps
    /// them to the wire/template row shape.
    private func fetchUserRows(on db: Database, viewerID: UUID?) async throws -> [AdminUserRow] {
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

        // This list belongs to no one course, so the staff ring means "teaches
        // somewhere", as on the account page (docs/student-wardrobe.md).
        let staff = try await AvatarStore.courseStaff(among: users.compactMap(\.id), on: db)
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
                row.hasAvatar = true
            }
            rows.append(row)
        }
        return rows
    }

    // MARK: - GET /admin/storage

    @Sendable
    func storagePage(req: Request) async throws -> View {
        let storage = try await StorageUsage.context(app: req.application)
        let ctx = AdminStoragePageContext(
            currentUser: req.currentUserContext,
            activeAdminTab: "storage",
            storage: storage,
            assignmentRows: AdminStorageShareRow.rows(
                from: storage.assignments, totalBytes: storage.totalBytes)
        )
        return try await req.view.render("admin-storage", ctx)
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
            throw Abort(.notFound)
        }

        // An admin who demotes themselves may leave no way back. Another admin
        // must make the change, so at least one admin always remains.
        if try req.auth.require(APIUser.self).id == uuid {
            throw AppError.forbidden(action: "change your own role")
        }

        let body = try req.content.decode(RoleBody.self)
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

        let body = try req.content.decode(AutoStartBody.self)
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
    func alertsPage(req: Request) async throws -> View {
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
        let ctx = AdminAlertsContext(
            currentUser: req.currentUserContext,
            activeAdminTab: "alerts",
            enabled: configuration.enabled,
            webhookURL: effectiveURL,
            webhookURLFromEnvironment: !envURL.isEmpty,
            checkIntervalSeconds: Int(configuration.checkIntervalSeconds),
            cooldownSeconds: Int(configuration.cooldownSeconds),
            runnerOfflineSeconds: Int(configuration.runnerOfflineSeconds),
            queueDepthThreshold: configuration.queueDepthThreshold,
            oldestPendingSeconds: Int(configuration.oldestPendingSeconds),
            errorRatePercent: Int((configuration.errorRateThreshold * 100).rounded()),
            rules: ruleRows,
            webhookDisplay: AdminAlertsPresentation.webhookDisplay(effectiveURL),
            hasLastDelivery: lastDelivery != nil,
            lastDeliveryISO: lastDelivery?.iso ?? "",
            lastDeliveryResult: lastDelivery?.result ?? "",
            firingDays: DayGrouper.group(firingRows, occurredAt: \.occurredAt),
            firingCount: firingRows.count,
            flashSuccess: query.ok,
            flashError: query.error
        )
        return try await req.view.render("alerts", ctx)
    }

    // MARK: - POST /admin/alerts/config

    @Sendable
    func updateAlertsConfig(req: Request) async throws -> Response {
        struct AlertsConfigBody: Content { var webhookURL: String? }
        let body = try req.content.decode(AlertsConfigBody.self)
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
            return req.redirect(to: adminNoticeRedirect("/admin/alerts", error: "Test alert failed: \(error)"))
        }
    }

    // MARK: - GET /admin/users/:userID

    @Sendable
    func userDetail(req: Request) async throws -> View {
        guard
            let idString = req.parameters.get("userID"),
            let userID = UUID(uuidString: idString),
            let user = try await APIUser.find(userID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let allCourses = try await APICourse.query(on: req.db)
            .filter(\.$isArchived == false)
            .all()
            .sorted(by: courseListPrecedes)

        let enrollments = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$userID == userID)
            .with(\.$course)
            .all()

        let enrolledIDs = Set(enrollments.map { $0.$course.id })

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

        return try await req.view.render(
            "admin-user",
            AdminUserDetailContext(
                currentUser: req.currentUserContext,
                targetUserID: idString,
                displayName: user.displayName,
                username: user.username,
                role: user.role,
                enrolledCourses: enrolledRows,
                availableCourses: availableRows
            ))
    }

    // MARK: - POST /admin/users/:userID/delete

    @Sendable
    func deleteUser(req: Request) async throws -> Response {
        guard
            let idString = req.parameters.get("userID"),
            let uuid = UUID(uuidString: idString),
            let user = try await APIUser.find(uuid, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let deletedUsername = user.username
        let deletedRole = user.role

        // The columns that name a user with NO foreign key on either backend
        // are cleared here, before the row goes (docs/operational-diagnostics.md
        // "User-row foreign-key cascade"). Every other reference is a declared
        // FK, which both backends enforce: SQLite because `configureDatabase`
        // turns foreign keys on. `UserReferenceScanTests` lists the FK-less
        // columns, so a new one must be cleared here or kept on purpose there
        // (#1808).
        //
        // `class_achievements.user_id` and `submissions.retested_by_user_id`
        // gained an FK on Postgres only (`AddUserFKConstraints`); SQLite cannot
        // add one after the fact, so both are cleared here for both backends.
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

func assignmentCountsByCourse(on db: Database) async throws -> [UUID: Int] {
    // DB-side grouped COUNT rather than loading every assignment row into
    // memory and tallying in Swift. Falls back to the in-memory tally on the
    // (currently nonexistent) non-SQL driver.
    guard let sql = db as? SQLDatabase else {
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
