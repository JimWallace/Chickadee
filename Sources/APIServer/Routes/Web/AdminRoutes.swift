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

import Vapor
import Fluent
import Core
import Foundation

struct AdminRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let admin = routes.grouped("admin")
        admin.get(use: dashboard)
        admin.get("runners", use: runners)
        admin.get("runners", ":runnerID", use: runnerDetail)
        admin.get("workers", use: workers)
        admin.post("users", ":userID", "role", use: changeRole)
        admin.post("runner-secret", use: updateWorkerSecret)
        admin.post("worker-secret", use: updateWorkerSecret)
        admin.post("runner-autostart", use: updateLocalRunnerAutoStart)
        admin.get("alerts", use: alertsPage)
        admin.post("alerts", "config", use: updateAlertsConfig)
        admin.post("alerts", "test", use: sendTestAlert)
        admin.get("courses", "new", use: newCourseForm)
        admin.post("courses", use: createCourse)
        admin.get("courses", ":courseID", use: courseDetail)
        admin.post("courses", ":courseID", "edit", use: editCourse)
        admin.post("courses", ":courseID", "archive", use: toggleCourseArchive)
        admin.post("courses", ":courseID", "copy",    use: copyCourse)
        admin.post("courses", ":courseID", "delete",  use: deleteCourse)
        admin.post("courses", ":courseID", "enrollment-mode", use: setEnrollmentMode)
        admin.post("courses", ":courseID", "enroll-csv", use: adminBulkEnrollCSV)
        admin.post("courses", ":courseID", "unenroll", ":userID", use: unenrollUserFromCourse)
        admin.get("users", ":userID", use: userDetail)
        admin.post("users", ":userID", "delete", use: deleteUser)
        admin.post("users", ":userID", "enroll", use: adminEnrollUser)
        admin.post("users", ":userID", "unenroll", ":courseID", use: adminUnenrollUser)
    }

    // MARK: - GET /admin

    @Sendable
    func dashboard(req: Request) async throws -> View {
        let users = try await APIUser.query(on: req.db)
            .all()
            .sorted { lhs, rhs in
                switch (lhs.lastSeenAt, rhs.lastSeenAt) {
                case let (l?, r?):
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

        let userRows = users.map { u in
            AdminUserRow(
                id:        u.id?.uuidString ?? "",
                displayName: u.displayName,
                username:  u.username,
                role:      u.role,
                createdAt: u.createdAt.map { ISO8601DateFormatter().string(from: $0) } ?? "—",
                lastSeenAt: u.lastSeenAt.map { ISO8601DateFormatter().string(from: $0) }
            )
        }

        let workerRows = try await makeWorkerRows(req: req)
        let effectiveSecret = await req.application.workerSecretStore.effectiveSecret() ?? ""
        let localRunnerAutoStartEnabled = await req.application.localRunnerAutoStartStore.isEnabled()

        // Course management data — all three queries are independent so run in parallel.
        async let coursesFetch      = APICourse.query(on: req.db).sort(\.$createdAt).all()
        async let enrollmentsFetch  = enrolledStudentCountsByCourse(on: req.db)
        async let assignmentsFetch  = assignmentCountsByCourse(on: req.db)
        let (allCourses, enrollmentCounts, assignmentCounts) =
            try await (coursesFetch, enrollmentsFetch, assignmentsFetch)
        let bsSyncEnabled = req.application.brightSpaceClient != nil
        let courseRows = allCourses.compactMap { course -> AdminCourseRow? in
            guard let id = course.id else { return nil }
            return AdminCourseRow(
                id:                     id.uuidString,
                code:                   course.code,
                name:                   course.name,
                isArchived:             course.isArchived,
                enrollmentMode:         course.enrollmentMode.rawValue,
                enrollmentCount:        enrollmentCounts[id] ?? 0,
                assignmentCount:        assignmentCounts[id] ?? 0,
                createdAt:              course.createdAt.map { ISO8601DateFormatter().string(from: $0) } ?? "—",
                brightspaceOrgUnitID:   course.brightspaceOrgUnitID,
                brightspaceSyncEnabled: bsSyncEnabled
            )
        }

        let ctx = AdminContext(
            currentUser: req.currentUserContext,
            users:       userRows,
            workers:     workerRows,
            workerSecret: effectiveSecret,
            localRunnerAutoStartEnabled: localRunnerAutoStartEnabled,
            courses: courseRows,
            version: ChickadeeVersion.current
        )
        return try await req.view.render("admin", ctx)
    }

    // MARK: - GET /admin/runners

    @Sendable
    func runners(req: Request) async throws -> [AdminWorkerRow] {
        try await makeWorkerRows(req: req)
    }

    // MARK: - GET /admin/workers (compat alias)

    @Sendable
    func workers(req: Request) async throws -> [AdminWorkerRow] {
        try await makeWorkerRows(req: req)
    }

    // MARK: - GET /admin/runners/:runnerID

    @Sendable
    func runnerDetail(req: Request) async throws -> View {
        guard let runnerID = req.parameters.get("runnerID"), !runnerID.isEmpty else {
            throw Abort(.notFound)
        }

        let workerRows = try await makeWorkerRows(req: req)
        let worker: AdminWorkerRow
        if let found = workerRows.first(where: { $0.workerID == runnerID }) {
            worker = found
        } else {
            // Runner was pruned from the in-memory store (offline >60 min).
            // Reconstruct a minimal row from the most recent DB snapshot so
            // the detail page can still render historical data instead of 404.
            guard let latestSnapshot = try await RunnerSnapshot.query(on: req.db)
                .filter(\.$runnerID == runnerID)
                .sort(\.$recordedAt, .descending)
                .first()
            else {
                throw Abort(.notFound)
            }
            let iso = ISO8601DateFormatter()
            let processedCount = try await APISubmission.query(on: req.db)
                .filter(\.$workerID == runnerID)
                .filter(\.$status ~~ ["complete", "failed"])
                .count()
            let avgData = try? await req.application.diagnostics.rollingAverages(
                for: [runnerID], sampleSize: 50, on: req.db
            )
            let avg = avgData?[runnerID]
            worker = AdminWorkerRow(
                workerID: runnerID,
                hostname: latestSnapshot.hostname ?? "",
                runnerVersion: latestSnapshot.runnerVersion ?? "",
                maxConcurrentJobs: latestSnapshot.maxJobs,
                lastActive: iso.string(from: latestSnapshot.recordedAt),
                assignedJobs: 0,
                jobsProcessed: processedCount,
                avgExecutionMs: avg?.avgExecutionMs,
                avgQueueWaitMs: avg?.avgQueueWaitMs,
                avgExecutionFormatted: avg?.avgExecutionMs.map(formatMs),
                avgQueueWaitFormatted: avg?.avgQueueWaitMs.map(formatMs)
            )
        }
        let runnerProfile = try? await req.application.runnerProfiles.profile(for: runnerID, on: req.db)

        let snapshots = try await RunnerSnapshot.query(on: req.db)
            .filter(\.$runnerID == runnerID)
            .sort(\.$recordedAt, .descending)
            .limit(50)
            .all()

        let recentJobs = try await JobExecutionMetric.query(on: req.db)
            .filter(\.$runnerID == runnerID)
            .sort(\.$completedAt, .descending)
            .limit(50)
            .all()

        // Batch-fetch usernames for all distinct user IDs in recent jobs.
        let userIDs = Array(Set(recentJobs.compactMap { $0.userID }))
        let users = userIDs.isEmpty ? [] : try await APIUser.query(on: req.db)
            .filter(\.$id ~~ userIDs)
            .all()
        let usernameByID: [UUID: String] = Dictionary(uniqueKeysWithValues: users.compactMap {
            guard let id = $0.id else { return nil }
            return (id, $0.username)
        })

        // Earliest snapshot for this runner tells us how long it's been online.
        let firstSnapshot = try await RunnerSnapshot.query(on: req.db)
            .filter(\.$runnerID == runnerID)
            .sort(\.$recordedAt, .ascending)
            .first()
        let firstSeenAt = firstSnapshot.map { iso8601String($0.recordedAt) }

        var statusCounts: [String: Int] = [:]
        for job in recentJobs {
            guard let status = job.finalStatus else { continue }
            statusCounts[status, default: 0] += 1
        }

        let snapshotRows = snapshots.map {
            let utilizationPercent = $0.maxJobs > 0
                ? Int((Double($0.activeJobs) / Double($0.maxJobs) * 100).rounded())
                : 0
            return AdminRunnerSnapshotRow(
                recordedAt: iso8601String($0.recordedAt),
                activeJobs: $0.activeJobs,
                maxJobs: $0.maxJobs,
                activeJobsLabel: "\($0.activeJobs) / \($0.maxJobs)",
                utilizationPercent: utilizationPercent,
                lastPollAt: $0.lastPollAt.map(iso8601String)
            )
        }

        let overheadSamples = recentJobs.compactMap { overheadMs(for: $0) }
        let stageBreakdowns = recentJobs.map(stageBreakdown(for:))
        let jobRows = recentJobs.map {
            AdminRunnerJobRow(
                submissionID: $0.submissionID,
                assignmentID: $0.assignmentID?.uuidString,
                username: $0.userID.flatMap { usernameByID[$0] },
                finalStatus: $0.finalStatus ?? "unknown",
                queueWaitMs: $0.queueWaitMs,
                executionMs: $0.executionMs,
                queueWaitFormatted: $0.queueWaitMs.map(formatMs),
                executionFormatted: $0.executionMs.map(formatMs),
                totalProcessingMs: $0.totalProcessingMs,
                totalProcessingFormatted: $0.totalProcessingMs.map(formatMs),
                workdirPeakBytes: $0.workdirPeakBytes,
                workdirPeakFormatted: $0.workdirPeakBytes.map(formatBytes),
                completedAt: $0.completedAt.map(iso8601String)
            )
        }

        let summary = AdminRunnerSummary(
            activeJobs: worker.assignedJobs,
            maxJobs: worker.maxConcurrentJobs,
            jobsProcessed: worker.jobsProcessed,
            avgExecutionFormatted: worker.avgExecutionFormatted,
            avgQueueWaitFormatted: worker.avgQueueWaitFormatted,
            avgOverheadFormatted: average(overheadSamples).map(formatMs),
            avgCacheAcquireFormatted: average(stageBreakdowns.compactMap { $0?.cacheAcquireMs }).map(formatMs),
            avgDownloadFormatted: average(stageBreakdowns.compactMap { $0?.downloadMs }).map(formatMs),
            avgPrepFormatted: average(stageBreakdowns.compactMap { $0?.prepMs }).map(formatMs),
            passedCount: statusCounts["passed", default: 0],
            failedCount: statusCounts["failed", default: 0],
            errorCount: statusCounts["error", default: 0],
            timeoutCount: statusCounts["timeout", default: 0]
        )

        let tags: [String] = {
            guard let profile = runnerProfile?.capabilityProfile else { return [] }
            var values: [String] = []
            if !profile.platform.isEmpty {
                values.append(profile.platform)
            }
            if !profile.architecture.isEmpty {
                values.append(profile.architecture)
            }
            values.append(contentsOf: profile.languageVersions.map { "\($0.language) \($0.version)" })
            values.append(contentsOf: profile.capabilities.map(\.name))
            return values
        }()

        return try await req.view.render("admin-runner", AdminRunnerDetailContext(
            currentUser: req.currentUserContext,
            runner: worker,
            tags: tags,
            summary: summary,
            recentJobs: jobRows,
            snapshots: snapshotRows,
            firstSeenAt: firstSeenAt
        ))
    }

    // MARK: - POST /admin/users/:id/role

    @Sendable
    func changeRole(req: Request) async throws -> Response {
        struct RoleBody: Content { var role: String }

        guard
            let idString = req.parameters.get("userID"),
            let uuid     = UUID(uuidString: idString),
            let user     = try await APIUser.find(uuid, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let body = try req.content.decode(RoleBody.self)
        guard ["student", "instructor", "admin"].contains(body.role) else {
            throw Abort(.badRequest, reason: "Invalid role: \(body.role)")
        }

        user.role = body.role
        try await user.save(on: req.db)
        return req.redirect(to: "/admin")
    }

    // MARK: - POST /admin/runner-secret

    @Sendable
    func updateWorkerSecret(req: Request) async throws -> Response {
        struct WorkerSecretBody: Content { var secret: String }
        let body = try req.content.decode(WorkerSecretBody.self)
        let trimmed = body.secret.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            await req.application.workerSecretStore.setRuntimeOverride(nil)
            if let persisted = readWorkerSecretFromDisk(workerSecretFilePath: req.application.workerSecretFilePath) {
                await req.application.workerSecretStore.setRuntimeOverride(persisted)
                req.logger.info("Admin reset runtime runner secret to persisted value.")
            }
            req.logger.info("Admin cleared runtime runner secret override.")
        } else {
            await req.application.workerSecretStore.setRuntimeOverride(trimmed)
            writeWorkerSecretToDisk(secret: trimmed, workerSecretFilePath: req.application.workerSecretFilePath)
            req.logger.info("Admin updated runtime runner secret override.")
        }
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
            let userID   = UUID(uuidString: idString),
            let user     = try await APIUser.find(userID, on: req.db)
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

        let enrolledRows = enrollments
            .compactMap { e -> AdminUserCourseRow? in
                guard let id = e.course.id else { return nil }
                return AdminUserCourseRow(id: id.uuidString, code: e.course.code, name: e.course.name)
            }
            .sorted { $0.code < $1.code }

        let availableRows = allCourses.compactMap { c -> AdminUserCourseRow? in
            guard let id = c.id, !enrolledIDs.contains(id) else { return nil }
            return AdminUserCourseRow(id: id.uuidString, code: c.code, name: c.name)
        }

        return try await req.view.render("admin-user", AdminUserDetailContext(
            currentUser:      req.currentUserContext,
            targetUserID:     idString,
            displayName:      user.displayName,
            username:         user.username,
            role:             user.role,
            enrolledCourses:  enrolledRows,
            availableCourses: availableRows
        ))
    }

    // MARK: - POST /admin/users/:userID/delete

    @Sendable
    func deleteUser(req: Request) async throws -> Response {
        guard
            let idString = req.parameters.get("userID"),
            let uuid     = UUID(uuidString: idString),
            let user     = try await APIUser.find(uuid, on: req.db)
        else {
            throw Abort(.notFound)
        }

        try await APICourseEnrollment.query(on: req.db)
            .filter(\.$userID == uuid)
            .delete()
        try await user.delete(on: req.db)
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

private func makeWorkerRows(req: Request) async throws -> [AdminWorkerRow] {
    let iso = ISO8601DateFormatter()
    let workers = await req.application.workerActivityStore.snapshotsSortedByRecent()
    let submissions = try await APISubmission.query(on: req.db).all()

    var assignedByWorkerID: [String: Int] = [:]
    var processedByWorkerID: [String: Int] = [:]
    for submission in submissions {
        guard let workerID = submission.workerID, !workerID.isEmpty else { continue }
        if submission.status == "assigned" {
            assignedByWorkerID[workerID, default: 0] += 1
        }
        if submission.status == "complete" || submission.status == "failed" {
            processedByWorkerID[workerID, default: 0] += 1
        }
    }

    // Fetch rolling averages (last 50 jobs per runner) via the diagnostics service.
    let runnerIDs = workers.map(\.workerID).filter { !$0.isEmpty }
    let averages = (try? await req.application.diagnostics.rollingAverages(
        for: runnerIDs, sampleSize: 50, on: req.db
    )) ?? [:]

    return workers.map { snapshot in
        let assigned  = assignedByWorkerID[snapshot.workerID,  default: 0]
        let processed = processedByWorkerID[snapshot.workerID, default: 0]
        let avg = averages[snapshot.workerID]
        let avgExec = avg?.avgExecutionMs
        let avgWait = avg?.avgQueueWaitMs
        return AdminWorkerRow(
            workerID:              snapshot.workerID,
            hostname:              snapshot.hostname,
            runnerVersion:         snapshot.runnerVersion,
            maxConcurrentJobs:     snapshot.maxConcurrentJobs,
            lastActive:            iso.string(from: snapshot.lastActive),
            assignedJobs:          assigned,
            jobsProcessed:         processed,
            avgExecutionMs:        avgExec,
            avgQueueWaitMs:        avgWait,
            avgExecutionFormatted: avgExec.map(formatMs),
            avgQueueWaitFormatted: avgWait.map(formatMs)
        )
    }
    .sorted { lhs, rhs in
        let compare = lhs.workerID.localizedStandardCompare(rhs.workerID)
        if compare == .orderedSame {
            return lhs.hostname.localizedStandardCompare(rhs.hostname) == .orderedAscending
        }
        return compare == .orderedAscending
    }
}

private func formatMs(_ ms: Int) -> String {
    if ms < 1000 {
        return "\(ms)ms"
    }

    let totalSeconds = ms / 1000
    if totalSeconds < 60 {
        return "\(totalSeconds)s"
    }

    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
        if seconds == 0 {
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        return "\(hours)h \(minutes)m"
    }

    return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
}

private func formatBytes(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let kb = Double(bytes) / 1024
    if kb < 1024 { return String(format: "%.0f KB", kb) }
    let mb = kb / 1024
    if mb < 100 { return String(format: "%.1f MB", mb) }
    if mb < 1024 { return String(format: "%.0f MB", mb) }
    let gb = mb / 1024
    return String(format: "%.1f GB", gb)
}

private func overheadMs(for metric: JobExecutionMetric) -> Int? {
    guard
        let total = metric.totalProcessingMs,
        let queueWait = metric.queueWaitMs,
        let execution = metric.executionMs
    else {
        return nil
    }

    return max(0, total - queueWait - execution)
}

private struct StageBreakdown {
    let cacheAcquireMs: Int?
    let downloadMs: Int?
    let prepMs: Int?
    let makeMs: Int?
    let formatted: String?
}

private func stageBreakdown(for metric: JobExecutionMetric) -> StageBreakdown? {
    let cacheAcquireMs = metric.testSetupAcquireMs
    let downloadMs = metric.submissionDownloadMs
    let prepMs = sum([
        metric.workdirSetupMs,
        metric.submissionDirSetupMs,
        metric.submissionUnpackMs,
        metric.starterCleanupMs,
        metric.submissionPrepareMs,
        metric.runtimeHelperSetupMs,
    ])
    let makeMs = metric.makeStepMs

    let parts = [
        cacheAcquireMs.map { "cache \(formatMs($0))" },
        downloadMs.map { "dl \(formatMs($0))" },
        prepMs.map { "prep \(formatMs($0))" },
        makeMs.map { "make \(formatMs($0))" },
    ].compactMap { $0 }

    guard !parts.isEmpty else { return nil }
    return StageBreakdown(
        cacheAcquireMs: cacheAcquireMs,
        downloadMs: downloadMs,
        prepMs: prepMs,
        makeMs: makeMs,
        formatted: parts.joined(separator: " · ")
    )
}

private func average(_ values: [Int]) -> Int? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / values.count
}

private func sum(_ values: [Int?]) -> Int? {
    let present = values.compactMap { $0 }
    guard !present.isEmpty else { return nil }
    return present.reduce(0, +)
}

private func iso8601String(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

func assignmentCountsByCourse(on db: Database) async throws -> [UUID: Int] {
    let assignments = try await APIAssignment.query(on: db).all()
    var counts: [UUID: Int] = [:]
    for a in assignments {
        let cid = a.courseID
        counts[cid, default: 0] += 1
    }
    return counts
}
