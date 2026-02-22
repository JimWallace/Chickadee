// APIServer/Routes/Web/AdminRoutes.swift
//
// Admin-only routes for user management.
// Assignment publishing/open/close/delete have moved to AssignmentRoutes (instructor+).
// All routes here require admin role (enforced in routes.swift).
//
//   GET  /admin                        → admin.leaf  (user management dashboard)
//   POST /admin/users/:id/role         → change a user's role
//   POST /admin/worker-secret          → set/clear runtime worker secret

import Vapor
import Fluent

struct AdminRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let admin = routes.grouped("admin")
        admin.get(use: dashboard)
        admin.post("users", ":userID", "role", use: changeRole)
        admin.post("worker-secret", use: updateWorkerSecret)
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

        let iso = ISO8601DateFormatter()
        let workers = await req.application.workerActivityStore.snapshotsSortedByRecent()
        let workerRows = workers.map {
            AdminWorkerRow(workerID: $0.workerID, lastActive: iso.string(from: $0.lastActive))
        }
        let effectiveSecret = await req.application.workerSecretStore.effectiveSecret() ?? ""

        let ctx = AdminContext(
            currentUser: req.currentUserContext,
            users:       userRows,
            workers:     workerRows,
            workerSecret: effectiveSecret
        )
        return try await req.view.render("admin", ctx)
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

    // MARK: - POST /admin/worker-secret

    @Sendable
    func updateWorkerSecret(req: Request) async throws -> Response {
        struct WorkerSecretBody: Content { var secret: String }
        let body = try req.content.decode(WorkerSecretBody.self)
        let trimmed = body.secret.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            await req.application.workerSecretStore.setRuntimeOverride(nil)
            req.logger.info("Admin cleared runtime worker secret override.")
        } else {
            await req.application.workerSecretStore.setRuntimeOverride(trimmed)
            req.logger.info("Admin updated runtime worker secret override.")
        }
        return req.redirect(to: "/admin")
    }

}

// MARK: - View context types

private struct AdminUserRow: Encodable {
    let id: String
    let username: String
    let role: String
    let createdAt: String
}

private struct AdminWorkerRow: Encodable {
    let workerID: String
    let lastActive: String
}

private struct AdminContext: Encodable {
    let currentUser: CurrentUserContext?
    let users: [AdminUserRow]
    let workers: [AdminWorkerRow]
    let workerSecret: String
}
