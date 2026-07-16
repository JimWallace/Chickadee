// Tests/APITests/CollapseUserRolesMigrationTests.swift
//
// #417 Slice G2 — the CollapseUserRoles migration rewrites every legacy global
// `student` / `instructor` row to `user`, leaving `admin` and `mcp` untouched.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct CollapseUserRolesMigrationTests {

    private func role(_ username: String, on app: Application) async throws -> String? {
        try await APIUser.query(on: app.db).filter(\.$username == username).first()?.role
    }

    @Test func rewritesStudentAndInstructorToUserAndLeavesAdminAndMCP() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try await configureTestDatabase(app)

            // configureTestDatabase already ran the migration against an empty
            // users table (a no-op). Seed one row per legacy/kept role AFTER,
            // then run the migration's prepare directly to exercise the rewrite.
            let rows: [(String, String)] = [
                ("legacy_student", "student"),
                ("legacy_instructor", "instructor"),
                ("real_admin", "admin"),
                ("agent", "mcp"),
                ("already_user", "user"),
            ]
            for (username, role) in rows {
                try await APIUser(username: username, passwordHash: "x", role: role).save(on: app.db)
            }

            try await CollapseUserRoles().prepare(on: app.db)

            // The two retired roles collapse to `user`.
            #expect(try await role("legacy_student", on: app) == UserRole.user.rawValue)
            #expect(try await role("legacy_instructor", on: app) == UserRole.user.rawValue)
            // admin, mcp, and an already-`user` row are untouched.
            #expect(try await role("real_admin", on: app) == UserRole.admin.rawValue)
            #expect(try await role("agent", on: app) == UserRole.mcp.rawValue)
            #expect(try await role("already_user", on: app) == UserRole.user.rawValue)
        }
    }

    @Test func isIdempotent() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try await configureTestDatabase(app)
            try await APIUser(username: "legacy_instructor", passwordHash: "x", role: "instructor")
                .save(on: app.db)

            try await CollapseUserRoles().prepare(on: app.db)
            // Second run finds no student/instructor rows and changes nothing.
            try await CollapseUserRoles().prepare(on: app.db)

            #expect(try await role("legacy_instructor", on: app) == UserRole.user.rawValue)
        }
    }
}
