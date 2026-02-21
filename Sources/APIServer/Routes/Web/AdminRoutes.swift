// APIServer/Routes/Web/AdminRoutes.swift
//
// Admin-only routes for class management.
// All routes require admin role (enforced in routes.swift).
//
//   GET    /admin                          → admin.leaf  (dashboard)
//   POST   /admin/users/:id/role           → change a user's role
//   POST   /admin/assignments              → publish a test setup as an assignment
//   POST   /admin/assignments/:id/close    → close an assignment (no new submissions)
//   POST   /admin/assignments/:id/delete   → unpublish (remove from students' view)

import Vapor
import Fluent

struct AdminRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let admin = routes.grouped("admin")
        admin.get(use: dashboard)
        admin.post("users", ":userID", "role",         use: changeRole)
        admin.post("assignments",                           use: publishAssignment)
        admin.post("assignments", ":assignmentID", "close",  use: closeAssignment)
        admin.post("assignments", ":assignmentID", "delete", use: unpublishAssignment)
    }

    // MARK: - GET /admin

    @Sendable
    func dashboard(req: Request) async throws -> View {
        let users = try await APIUser.query(on: req.db)
            .sort(\.$createdAt)
            .all()

        let assignments = try await APIAssignment.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .all()

        let allSetups = try await APITestSetup.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .all()

        let publishedSetupIDs = Set(assignments.map(\.testSetupID))
        let unpublishedSetups = allSetups.filter { !publishedSetupIDs.contains($0.id ?? "") }

        let userRows = users.map { u in
            AdminUserRow(
                id:        u.id?.uuidString ?? "",
                username:  u.username,
                role:      u.role,
                createdAt: u.createdAt.map { ISO8601DateFormatter().string(from: $0) } ?? "—"
            )
        }

        let assignmentRows = assignments.map { a in
            AdminAssignmentRow(
                id:          a.id?.uuidString ?? "",
                testSetupID: a.testSetupID,
                title:       a.title,
                isOpen:      a.isOpen,
                dueAt:       a.dueAt.map { ISO8601DateFormatter().string(from: $0) }
            )
        }

        let setupRows = unpublishedSetups.map { s in
            AdminSetupRow(id: s.id ?? "")
        }

        let ctx = AdminContext(
            currentUser:        req.currentUserContext,
            users:              userRows,
            assignments:        assignmentRows,
            unpublishedSetups:  setupRows
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

    // MARK: - POST /admin/assignments

    @Sendable
    func publishAssignment(req: Request) async throws -> Response {
        struct PublishBody: Content {
            var testSetupID: String
            var title: String
            var dueAt: String?      // ISO8601 string or empty
        }

        let body = try req.content.decode(PublishBody.self)

        guard let _ = try await APITestSetup.find(body.testSetupID, on: req.db) else {
            throw Abort(.badRequest, reason: "Unknown testSetupID: \(body.testSetupID)")
        }

        let due: Date?
        if let raw = body.dueAt, !raw.isEmpty {
            due = ISO8601DateFormatter().date(from: raw)
        } else {
            due = nil
        }

        let assignment = APIAssignment(
            testSetupID: body.testSetupID,
            title:       body.title.isEmpty ? body.testSetupID : body.title,
            dueAt:       due,
            isOpen:      true
        )
        try await assignment.save(on: req.db)
        return req.redirect(to: "/admin")
    }

    // MARK: - POST /admin/assignments/:id/close

    @Sendable
    func closeAssignment(req: Request) async throws -> Response {
        guard
            let idString   = req.parameters.get("assignmentID"),
            let uuid       = UUID(uuidString: idString),
            let assignment = try await APIAssignment.find(uuid, on: req.db)
        else {
            throw Abort(.notFound)
        }
        assignment.isOpen = false
        try await assignment.save(on: req.db)
        return req.redirect(to: "/admin")
    }

    // MARK: - POST /admin/assignments/:id/delete

    @Sendable
    func unpublishAssignment(req: Request) async throws -> Response {
        guard
            let idString   = req.parameters.get("assignmentID"),
            let uuid       = UUID(uuidString: idString),
            let assignment = try await APIAssignment.find(uuid, on: req.db)
        else {
            throw Abort(.notFound)
        }
        try await assignment.delete(on: req.db)
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

private struct AdminAssignmentRow: Encodable {
    let id: String
    let testSetupID: String
    let title: String
    let isOpen: Bool
    let dueAt: String?
}

private struct AdminSetupRow: Encodable {
    let id: String
}

private struct AdminContext: Encodable {
    let currentUser: CurrentUserContext?
    let users: [AdminUserRow]
    let assignments: [AdminAssignmentRow]
    let unpublishedSetups: [AdminSetupRow]
}
