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
        admin.post("users", ":userID", "enroll", use: adminEnrollUser)
        admin.post("users", ":userID", "unenroll", ":courseID", use: adminUnenrollUser)
    }

    // MARK: - GET /admin

    @Sendable
    func dashboard(req: Request) async throws -> View {
        let users = try await APIUser.query(on: req.db)
            .sort(\.$createdAt)
            .all()

        let userRows = users.map { u in
            AdminUserRow(
                id:        u.id?.uuidString ?? "",
                displayName: u.displayName,
                username:  u.username,
                role:      u.role,
                createdAt: u.createdAt.map { ISO8601DateFormatter().string(from: $0) } ?? "—",
                lastLoginAt: u.lastLoginAt.map { ISO8601DateFormatter().string(from: $0) }
            )
        }

        let workerRows = try await makeWorkerRows(req: req)
        let effectiveSecret = await req.application.workerSecretStore.effectiveSecret() ?? ""
        let localRunnerAutoStartEnabled = await req.application.localRunnerAutoStartStore.isEnabled()

        // Course management data — all three queries are independent so run in parallel.
        async let coursesFetch      = APICourse.query(on: req.db).sort(\.$createdAt).all()
        async let enrollmentsFetch  = enrollmentCountsByCourse(on: req.db)
        async let assignmentsFetch  = assignmentCountsByCourse(on: req.db)
        let (allCourses, enrollmentCounts, assignmentCounts) =
            try await (coursesFetch, enrollmentsFetch, assignmentsFetch)
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
                createdAt: course.createdAt.map { ISO8601DateFormatter().string(from: $0) } ?? "—"
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
        guard let worker = workerRows.first(where: { $0.workerID == runnerID }) else {
            throw Abort(.notFound)
        }

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

        var statusCounts: [String: Int] = [:]
        for job in recentJobs {
            guard let status = job.finalStatus else { continue }
            statusCounts[status, default: 0] += 1
        }

        let snapshotRows = snapshots.map {
            AdminRunnerSnapshotRow(
                recordedAt: iso8601String($0.recordedAt),
                activeJobs: $0.activeJobs,
                maxJobs: $0.maxJobs,
                availableCapacity: $0.availableCapacity,
                lastPollAt: $0.lastPollAt.map(iso8601String),
                lastHeartbeatAt: $0.lastHeartbeatAt.map(iso8601String)
            )
        }

        let jobRows = recentJobs.map {
            AdminRunnerJobRow(
                submissionID: $0.submissionID,
                assignmentID: $0.assignmentID?.uuidString,
                finalStatus: $0.finalStatus ?? "unknown",
                queueWaitFormatted: $0.queueWaitMs.map(formatMs),
                executionFormatted: $0.executionMs.map(formatMs),
                totalProcessingFormatted: $0.totalProcessingMs.map(formatMs),
                completedAt: $0.completedAt.map(iso8601String),
                testsPassed: $0.testsPassed ?? 0,
                testsFailed: $0.testsFailed ?? 0,
                testsErrored: $0.testsErrored ?? 0,
                testsTimedOut: $0.testsTimedOut ?? 0,
                skippedCount: $0.skippedCount ?? 0
            )
        }

        let summary = AdminRunnerSummary(
            activeJobs: worker.assignedJobs,
            maxJobs: worker.maxConcurrentJobs,
            jobsProcessed: worker.jobsProcessed,
            avgExecutionFormatted: worker.avgExecutionFormatted,
            avgQueueWaitFormatted: worker.avgQueueWaitFormatted,
            passedCount: statusCounts["passed", default: 0],
            failedCount: statusCounts["failed", default: 0],
            errorCount: statusCounts["error", default: 0],
            timeoutCount: statusCounts["timeout", default: 0]
        )

        return try await req.view.render("admin-runner", AdminRunnerDetailContext(
            currentUser: req.currentUserContext,
            runner: worker,
            summary: summary,
            recentJobs: jobRows,
            snapshots: snapshotRows
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

private func iso8601String(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

private func enrollmentCountsByCourse(on db: Database) async throws -> [UUID: Int] {
    let enrollments = try await APICourseEnrollment.query(on: db).all()
    var counts: [UUID: Int] = [:]
    for e in enrollments {
        counts[e.$course.id, default: 0] += 1
    }
    return counts
}

private func assignmentCountsByCourse(on db: Database) async throws -> [UUID: Int] {
    let assignments = try await APIAssignment.query(on: db).all()
    var counts: [UUID: Int] = [:]
    for a in assignments {
        let cid = a.courseID
        counts[cid, default: 0] += 1
    }
    return counts
}

