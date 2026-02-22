// APIServer/Routes/Web/AdminRoutes.swift
//
// Admin-only routes for user management.
// Assignment publishing/open/close/delete have moved to AssignmentRoutes (instructor+).
// All routes here require admin role (enforced in routes.swift).
//
//   GET  /admin                        → admin.leaf  (user management dashboard)
//   POST /admin/users/:id/role         → change a user's role
//   POST /admin/runner-secret          → set/clear runtime runner secret

import Vapor
import Fluent

struct AdminRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let admin = routes.grouped("admin")
        admin.get(use: dashboard)
        admin.get("runners", use: runners)
        admin.get("workers", use: workers)
        admin.post("users", ":userID", "role", use: changeRole)
        admin.post("runner-secret", use: updateWorkerSecret)
        admin.post("worker-secret", use: updateWorkerSecret)
        admin.post("runner-autostart", use: updateLocalRunnerAutoStart)
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
                username:  u.username,
                role:      u.role,
                createdAt: u.createdAt.map { ISO8601DateFormatter().string(from: $0) } ?? "—"
            )
        }

        let workerRows = try await makeWorkerRows(req: req)
        let effectiveSecret = await req.application.workerSecretStore.effectiveSecret() ?? ""
        let localRunnerAutoStartEnabled = await req.application.localRunnerAutoStartStore.isEnabled()

        let ctx = AdminContext(
            currentUser: req.currentUserContext,
            users:       userRows,
            workers:     workerRows,
            workerSecret: effectiveSecret,
            localRunnerAutoStartEnabled: localRunnerAutoStartEnabled
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

    return workers.map { snapshot in
        let assigned = assignedByWorkerID[snapshot.workerID, default: 0]
        let processed = processedByWorkerID[snapshot.workerID, default: 0]
        return AdminWorkerRow(
            workerID: snapshot.workerID,
            lastActive: iso.string(from: snapshot.lastActive),
            status: assigned > 0 ? "busy" : "idle",
            assignedJobs: assigned,
            jobsProcessed: processed
        )
    }
}

// MARK: - View context types

private struct AdminUserRow: Encodable {
    let id: String
    let username: String
    let role: String
    let createdAt: String
}

struct AdminWorkerRow: Content {
    let workerID: String
    let lastActive: String
    let status: String
    let assignedJobs: Int
    let jobsProcessed: Int
}

private struct AdminContext: Encodable {
    let currentUser: CurrentUserContext?
    let users: [AdminUserRow]
    let workers: [AdminWorkerRow]
    let workerSecret: String
    let localRunnerAutoStartEnabled: Bool
}
