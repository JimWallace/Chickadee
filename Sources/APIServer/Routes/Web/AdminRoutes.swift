// APIServer/Routes/Web/AdminRoutes.swift
//
// Admin-only routes for user management.
// Assignment publishing/open/close/delete have moved to AssignmentRoutes (instructor+).
// All routes here require admin role (enforced in routes.swift).
//
//   GET  /admin                              → admin.leaf  (user management dashboard)
//   POST /admin/users/:id/role               → change a user's role
//   POST /admin/runner-secret                → set/clear runtime runner secret
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
        admin.get("workers", use: workers)
        admin.post("users", ":userID", "role", use: changeRole)
        admin.post("runner-secret", use: updateWorkerSecret)
        admin.post("worker-secret", use: updateWorkerSecret)
        admin.post("runner-autostart", use: updateLocalRunnerAutoStart)
        admin.get("audit", use: auditPage)
        admin.get("alerts", use: alertsPage)
        admin.post("alerts", "config", use: updateAlertsConfig)
        admin.post("alerts", "test", use: sendTestAlert)
        admin.get("courses", "new", use: newCourseForm)
        admin.post("courses", use: createCourse)
        admin.get("courses", ":courseID", use: courseDetail)
        admin.post("courses", ":courseID", "edit", use: editCourse)
        admin.post("courses", ":courseID", "archive", use: toggleCourseArchive)
        admin.post("courses", ":courseID", "copy", use: copyCourse)
        admin.post("courses", ":courseID", "delete", use: deleteCourse)
        admin.post("courses", ":courseID", "enrollment-mode", use: setEnrollmentMode)
        admin.post("courses", ":courseID", "enroll-csv", use: adminBulkEnrollCSV)
        admin.post("courses", ":courseID", "unenroll", ":userID", use: unenrollUserFromCourse)
        admin.get("users", ":userID", use: userDetail)
        admin.post("users", ":userID", "delete", use: deleteUser)
        admin.post("users", ":userID", "enroll", use: adminEnrollUser)
        admin.post("users", ":userID", "unenroll", ":courseID", use: adminUnenrollUser)
        admin.get("mcp", use: mcpPage)
        admin.post("mcp", "accounts", use: createMCPAccount)
        admin.post("mcp", "accounts", ":userID", "token", use: mintMCPToken)
        admin.post("mcp", "accounts", ":userID", "delete", use: deleteMCPAccount)
    }

    // MARK: - GET /admin

    @Sendable
    func dashboard(req: Request) async throws -> View {
        let workerRows = try await makeWorkerRows(req: req)
        let effectiveSecret = await req.application.workerSecretStore.effectiveSecret() ?? ""
        let localRunnerAutoStartEnabled = await req.application.localRunnerAutoStartStore.isEnabled()

        // Course management data — all three queries are independent so run in parallel.
        async let coursesFetch = APICourse.query(on: req.db).sort(\.$createdAt).all()
        async let enrollmentsFetch = enrolledStudentCountsByCourse(on: req.db)
        async let assignmentsFetch = assignmentCountsByCourse(on: req.db)
        let (allCourses, enrollmentCounts, assignmentCounts) =
            try await (coursesFetch, enrollmentsFetch, assignmentsFetch)
        let bsSyncEnabled = req.application.brightSpaceClient != nil
        let courseRows = allCourses.compactMap { course -> AdminCourseRow? in
            guard let id = course.id else { return nil }
            return AdminCourseRow(
                id: id.uuidString,
                code: course.code,
                name: course.name,
                isArchived: course.isArchived,
                enrollmentMode: course.enrollmentMode.rawValue,
                enrollmentCount: enrollmentCounts[id] ?? 0,
                assignmentCount: assignmentCounts[id] ?? 0,
                createdAt: course.createdAt.map { ISO8601DateFormatter().string(from: $0) } ?? "—",
                brightspaceOrgUnitID: course.brightspaceOrgUnitID,
                brightspaceSyncEnabled: bsSyncEnabled
            )
        }

        let ctx = AdminContext(
            currentUser: req.currentUserContext,
            activeAdminTab: "overview",
            workers: workerRows,
            workerSecret: effectiveSecret,
            localRunnerAutoStartEnabled: localRunnerAutoStartEnabled,
            courses: courseRows,
            version: ChickadeeVersion.current
        )
        return try await req.view.render("admin", ctx)
    }

    // MARK: - GET /admin/users

    @Sendable
    func usersPage(req: Request) async throws -> View {
        let userRows = try await fetchUserRows(on: req.db)
        let ctx = AdminUsersContext(
            currentUser: req.currentUserContext,
            activeAdminTab: "users",
            users: userRows
        )
        return try await req.view.render("admin-users", ctx)
    }

    // MARK: - GET /admin/users-data
    //
    // JSON feed backing the Users tab's auto-refresh poll.  Returns the same
    // rows `usersPage` renders so the client can repaint the table in place.
    // Polls send the `X-Background-Refresh` header so they don't count as
    // session activity (see UserActivityMiddleware).

    @Sendable
    func usersData(req: Request) async throws -> [AdminUserRow] {
        try await fetchUserRows(on: req.db)
    }

    /// Loads every user, ordered most-recently-seen first (NULL last_seen
    /// rows sink to the bottom, then username, then join date), and maps
    /// them to the wire/template row shape.
    private func fetchUserRows(on db: Database) async throws -> [AdminUserRow] {
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

        let iso = ISO8601DateFormatter()
        return users.map { u in
            AdminUserRow(
                id: u.id?.uuidString ?? "",
                displayName: u.displayName,
                username: u.username,
                role: u.role,
                createdAt: u.createdAt.map { iso.string(from: $0) } ?? "—",
                lastSeenAt: u.lastSeenAt.map { iso.string(from: $0) }
            )
        }
    }

    // MARK: - GET /admin/storage

    @Sendable
    func storagePage(req: Request) async throws -> View {
        let storage = try await makeStorageContext(req: req)
        let ctx = AdminStoragePageContext(
            currentUser: req.currentUserContext,
            activeAdminTab: "storage",
            storage: storage
        )
        return try await req.view.render("admin-storage", ctx)
    }

    // MARK: - Storage breakdown

    /// Measures the persistent-volume sinks (submission/test-setup uploads,
    /// the results+logs dir, the static asset tree) and the database so an
    /// admin can see where disk is going.  Directory walks are blocking, so
    /// they run on the thread pool off the event loop.
    private func makeStorageContext(req: Request) async throws -> AdminStorageContext {
        let submissionsDir = req.application.submissionsDirectory
        let testSetupsDir = req.application.testSetupsDirectory
        let resultsDir = req.application.resultsDirectory
        let publicDir = req.application.directory.publicDirectory

        func dirSize(_ path: String) async throws -> Int {
            try await req.application.threadPool.runIfActive(eventLoop: req.eventLoop) {
                directorySizeBytes(at: path)
            }.get()
        }

        // Per-id footprints feed both the aggregate cards and the per-assignment
        // breakdown.  Submissions are stored flat (`<id>.<ext>`), so the
        // top-level sum equals a full recursive walk — we reuse it for the
        // "Submissions" card to avoid scanning that (potentially large) dir
        // twice.  Test setups have `shared/`+`notebooks/` subtrees, so the
        // card keeps an authoritative recursive walk.
        async let submissionSizesFetch = req.application.threadPool.runIfActive(
            eventLoop: req.eventLoop
        ) { topLevelFileSizesByID(inDirectory: submissionsDir) }.get()
        async let setupSizesFetch = req.application.threadPool.runIfActive(
            eventLoop: req.eventLoop
        ) { testSetupSizesByID(testSetupsDirectory: testSetupsDir) }.get()

        async let testSetupsBytes = dirSize(testSetupsDir)
        async let resultsBytes = dirSize(resultsDir)
        async let publicBytes = dirSize(publicDir)
        async let dbBytes = databaseSizeBytes(
            on: req.db, settings: req.application.appConfig.database)

        // Mapping rows for the per-assignment breakdown.
        async let assignmentsFetch = APIAssignment.query(on: req.db).all()
        async let coursesFetch = APICourse.query(on: req.db).all()
        async let submissionLinksFetch = APISubmission.query(on: req.db)
            .field(\.$id).field(\.$testSetupID).all()

        let submissionSizesByID = try await submissionSizesFetch
        let setupSizesByID = try await setupSizesFetch
        let testSetups = try await testSetupsBytes
        let results = try await resultsBytes
        let publicAssets = try await publicBytes
        let database = await dbBytes
        let submissions = submissionSizesByID.values.reduce(0, +)

        var rows = [
            AdminStorageRow(label: "Submissions", formatted: humanReadableBytes(submissions)),
            AdminStorageRow(label: "Test Setups", formatted: humanReadableBytes(testSetups)),
            AdminStorageRow(label: "Results & Logs", formatted: humanReadableBytes(results)),
            AdminStorageRow(label: "Static Assets", formatted: humanReadableBytes(publicAssets)),
        ]
        rows.append(
            AdminStorageRow(
                label: "Database",
                formatted: database.map(humanReadableBytes) ?? "—"))

        let total = submissions + testSetups + results + publicAssets + (database ?? 0)

        let assignments = try await assignmentsFetch
        let courses = try await coursesFetch
        let submissionLinks = try await submissionLinksFetch

        // Tally submission count + bytes per test setup.
        var submissionCountBySetup: [String: Int] = [:]
        var submissionBytesBySetup: [String: Int] = [:]
        for link in submissionLinks {
            submissionCountBySetup[link.testSetupID, default: 0] += 1
            if let subID = link.id {
                submissionBytesBySetup[link.testSetupID, default: 0] +=
                    submissionSizesByID[subID] ?? 0
            }
        }
        let codeByCourse = Dictionary(
            courses.compactMap { course in course.id.map { ($0, course.code) } },
            uniquingKeysWith: { first, _ in first })

        let assignmentRows =
            assignments
            .map { assignment -> AdminAssignmentStorageRow in
                let suiteBytes = setupSizesByID[assignment.testSetupID] ?? 0
                let subBytes = submissionBytesBySetup[assignment.testSetupID] ?? 0
                let count = submissionCountBySetup[assignment.testSetupID] ?? 0
                let rowTotal = suiteBytes + subBytes
                return AdminAssignmentStorageRow(
                    assignmentTitle: assignment.title,
                    courseCode: codeByCourse[assignment.courseID] ?? "—",
                    testSuiteFormatted: humanReadableBytes(suiteBytes),
                    submissionsFormatted: humanReadableBytes(subBytes),
                    submissionCount: count,
                    totalFormatted: humanReadableBytes(rowTotal),
                    testSuiteBytes: suiteBytes,
                    submissionsBytes: subBytes,
                    totalBytes: rowTotal
                )
            }
            .sorted { $0.totalBytes > $1.totalBytes }

        return AdminStorageContext(
            rows: rows,
            totalFormatted: humanReadableBytes(total),
            dbBackend: req.application.appConfig.database.backend.rawValue,
            assignments: assignmentRows
        )
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

        let body = try req.content.decode(RoleBody.self)
        guard ["student", "instructor", "admin"].contains(body.role) else {
            throw AppError.invalidParameter(
                name: "role",
                reason: "must be student, instructor, or admin (got '\(body.role)')")
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
        return req.redirect(to: "/admin")
    }

    // MARK: - POST /admin/runner-secret

    @Sendable
    func updateWorkerSecret(req: Request) async throws -> Response {
        struct WorkerSecretBody: Content { var secret: String }
        let body = try req.content.decode(WorkerSecretBody.self)
        let trimmed = body.secret.trimmingCharacters(in: .whitespacesAndNewlines)

        let action: String
        if trimmed.isEmpty {
            await req.application.workerSecretStore.setRuntimeOverride(nil)
            if let persisted = readWorkerSecretFromDisk(workerSecretFilePath: req.application.workerSecretFilePath) {
                await req.application.workerSecretStore.setRuntimeOverride(persisted)
                req.logger.info("Admin reset runtime runner secret to persisted value.")
            }
            req.logger.info("Admin cleared runtime runner secret override.")
            action = "cleared"
        } else {
            await req.application.workerSecretStore.setRuntimeOverride(trimmed)
            writeWorkerSecretToDisk(secret: trimmed, workerSecretFilePath: req.application.workerSecretFilePath)
            req.logger.info("Admin updated runtime runner secret override.")
            action = "rotated"
        }
        await AuditLogger.record(
            action: .runnerSecretRotated,
            targetType: .runner,
            metadata: ["change": action],
            on: req
        )
        return req.redirect(to: "/admin")
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

    // MARK: - GET /admin/audit

    @Sendable
    func auditPage(req: Request) async throws -> View {
        let entries = try await APIAuditLogEntry.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .limit(200)
            .all()

        let iso = ISO8601DateFormatter()
        let rows = entries.map { e -> AdminAuditRow in
            AdminAuditRow(
                timestamp: e.createdAt.map { iso.string(from: $0) } ?? "—",
                actor: e.actorUsername ?? "—",
                action: e.action,
                targetType: e.targetType,
                targetID: e.targetID,
                metadata: e.metadata ?? "",
                remoteAddr: e.remoteAddr ?? "—"
            )
        }
        return try await req.view.render(
            "admin-audit",
            AdminAuditContext(
                currentUser: req.currentUserContext, activeAdminTab: "audit", rows: rows)
        )
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

        let iso = ISO8601DateFormatter()
        let ruleRows = HealthRule.allCases.map { rule -> AdminAlertsRuleRow in
            let state = states[rule] ?? .initial
            return AdminAlertsRuleRow(
                rule: rule.rawValue,
                humanReadable: rule.humanReadable,
                isFiring: state.isFiring,
                lastFiredAt: state.lastFiredAt.map { iso.string(from: $0) }
            )
        }

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
            recentFirings: recent,
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
                return req.redirect(to: alertsRedirect(error: "Webhook URL must start with http:// or https://"))
            }
        }

        await req.application.serverHealthAlertMonitor.setWebhookURL(trimmed)
        req.logger.info("Admin updated alerts webhook URL (\(trimmed.isEmpty ? "cleared" : "set"))")
        return req.redirect(to: alertsRedirect(ok: trimmed.isEmpty ? "Webhook cleared." : "Webhook saved."))
    }

    // MARK: - POST /admin/alerts/test

    @Sendable
    func sendTestAlert(req: Request) async throws -> Response {
        let monitor = req.application.serverHealthAlertMonitor
        let effectiveURL = await monitor.effectiveWebhookURL() ?? ""

        if effectiveURL.isEmpty {
            return req.redirect(to: alertsRedirect(error: "No webhook URL configured. Set one above first."))
        }

        do {
            _ = try await monitor.dispatchTestAlert(application: req.application)
            return req.redirect(to: alertsRedirect(ok: "Test alert dispatched to webhook."))
        } catch {
            return req.redirect(to: alertsRedirect(error: "Test alert failed: \(error)"))
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
            .sort(\.$code)
            .all()

        let enrollments = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$userID == userID)
            .with(\.$course)
            .all()

        let enrolledIDs = Set(enrollments.map { $0.$course.id })

        let enrolledRows =
            enrollments
            .compactMap { e -> AdminUserCourseRow? in
                guard let id = e.course.id else { return nil }
                return AdminUserCourseRow(id: id.uuidString, code: e.course.code, name: e.course.name)
            }
            .sorted { $0.code < $1.code }

        let availableRows = allCourses.compactMap { c -> AdminUserCourseRow? in
            guard let id = c.id, !enrolledIDs.contains(id) else { return nil }
            return AdminUserCourseRow(id: id.uuidString, code: c.code, name: c.name)
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

        // Application-layer enforcement of the FK cascade behaviour
        // documented in docs/operational-diagnostics.md ("User-row FK
        // cascade").  Two rows here lack a DB-level constraint on
        // SQLite (the AddUserFKConstraints migration only adds the
        // constraints on Postgres because SQLite can't `ALTER TABLE
        // ADD CONSTRAINT FOREIGN KEY` post-hoc), so we enforce them
        // explicitly here.  Same logic runs on Postgres too — it just
        // becomes a no-op because the DB-level cascade already cleared
        // the same rows.
        try await APIClassAchievement.query(on: req.db)
            .filter(\.$userID == uuid)
            .delete()
        try await APISubmission.query(on: req.db)
            .filter(\.$retestedByUserID == uuid)
            .set(\.$retestedByUserID, to: nil)
            .update()

        try await APICourseEnrollment.query(on: req.db)
            .filter(\.$userID == uuid)
            .delete()
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

private func alertsRedirect(ok: String? = nil, error: String? = nil) -> String {
    var pairs: [String] = []
    if let okValue = ok?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
        pairs.append("ok=\(okValue)")
    }
    if let errorValue = error?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
        pairs.append("error=\(errorValue)")
    }
    return pairs.isEmpty ? "/admin/alerts" : "/admin/alerts?" + pairs.joined(separator: "&")
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
