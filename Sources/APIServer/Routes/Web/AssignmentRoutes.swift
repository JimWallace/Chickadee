// APIServer/Routes/Web/AssignmentRoutes.swift
//
// Instructor-facing assignment management routes.
// Requires instructor or admin role (enforced by routes.swift).
//
//   GET  /assignments                        → assignments.leaf (all setups + status)
//   POST /assignments                        → create draft assignment → redirect to validate
//   GET  /assignments/:assignmentID/validate → assignment-validate.leaf
//   GET  /assignments/:assignmentID/edit     → setup-edit.leaf (JupyterLite notebook editor) [Phase 8]
//   POST /assignments/:assignmentID/open     → set isOpen=true → redirect to /assignments
//   POST /assignments/:assignmentID/close    → set isOpen=false → redirect to /assignments
//   POST /assignments/:assignmentID/delete   → remove assignment record → redirect to /assignments

import Vapor
import Fluent
import Core
import Foundation

struct AssignmentRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let r = routes.grouped("assignments")
        r.get(use: list)
        r.post(use: publish)
        r.get(":assignmentID", "validate", use: validatePage)
        r.get(":assignmentID", "edit",     use: editPage)         // Phase 8
        r.post(":assignmentID", "open",    use: openAssignment)
        r.post(":assignmentID", "close",   use: closeAssignment)
        r.post(":assignmentID", "delete",  use: deleteAssignment)
    }

    // MARK: - GET /assignments

    @Sendable
    func list(req: Request) async throws -> View {
        let allSetups = try await APITestSetup.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .all()

        let allAssignments = try await APIAssignment.query(on: req.db).all()
        // Map testSetupID → assignment for quick lookup
        let assignmentBySetup = Dictionary(
            allAssignments.map { ($0.testSetupID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short

        let decoder = JSONDecoder()

        let rows: [AssignmentRow] = allSetups.map { setup in
            let assignment = assignmentBySetup[setup.id ?? ""]
            let setupID    = setup.id ?? ""
            let suiteCount: Int = {
                guard let data  = setup.manifest.data(using: .utf8),
                      let props = try? decoder.decode(TestProperties.self, from: data)
                else { return 0 }
                return props.testSuites.count
            }()

            let status: String
            if let a = assignment {
                // If isOpen is true → open; if false, check if it was ever open
                // (We don't track "was previously open" separately, so draft vs closed
                //  is distinguished by whether the title was explicitly set.)
                status = a.isOpen ? "open" : "closed"
            } else {
                status = "unpublished"
            }

            return AssignmentRow(
                setupID:      setupID,
                assignmentID: assignment?.id?.uuidString,
                title:        assignment?.title,
                isOpen:       assignment?.isOpen,
                dueAt:        assignment?.dueAt.map { fmt.string(from: $0) },
                status:       status,
                suiteCount:   suiteCount,
                createdAt:    setup.createdAt.map { fmt.string(from: $0) } ?? "—"
            )
        }

        let ctx = AssignmentsContext(
            currentUser: req.currentUserContext,
            rows: rows
        )
        return try await req.view.render("assignments", ctx)
    }

    // MARK: - POST /assignments
    // Creates a draft (isOpen: false) assignment and redirects to the validate page.

    @Sendable
    func publish(req: Request) async throws -> Response {
        struct PublishBody: Content {
            var testSetupID: String
            var title: String
            var dueAt: String?      // ISO8601 string from datetime-local input, or empty
        }

        let body = try req.content.decode(PublishBody.self)

        guard let _ = try await APITestSetup.find(body.testSetupID, on: req.db) else {
            throw Abort(.badRequest, reason: "Unknown testSetupID: \(body.testSetupID)")
        }

        // Reject if a draft/open assignment already exists for this setup.
        let existing = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == body.testSetupID)
            .count()
        if existing > 0 {
            // Already published — redirect back.
            return req.redirect(to: "/assignments")
        }

        let due: Date?
        if let raw = body.dueAt, !raw.isEmpty {
            // datetime-local sends "2026-04-01T14:00" — try ISO8601 with and without seconds.
            let iso = ISO8601DateFormatter()
            if let d = iso.date(from: raw) {
                due = d
            } else {
                // Try without timezone (datetime-local format)
                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
                due = fmt.date(from: raw)
            }
        } else {
            due = nil
        }

        let assignment = APIAssignment(
            testSetupID: body.testSetupID,
            title:       body.title.isEmpty ? body.testSetupID : body.title,
            dueAt:       due,
            isOpen:      false          // stays closed until instructor validates + opens
        )
        try await assignment.save(on: req.db)

        guard let id = assignment.id?.uuidString else {
            return req.redirect(to: "/assignments")
        }
        return req.redirect(to: "/assignments/\(id)/validate")
    }

    // MARK: - GET /assignments/:assignmentID/validate

    @Sendable
    func validatePage(req: Request) async throws -> View {
        guard
            let idStr      = req.parameters.get("assignmentID"),
            let uuid       = UUID(uuidString: idStr),
            let assignment = try await APIAssignment.find(uuid, on: req.db),
            let setup      = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let decoder = JSONDecoder()
        let suiteCount: Int = {
            guard let data  = setup.manifest.data(using: .utf8),
                  let props = try? decoder.decode(TestProperties.self, from: data)
            else { return 0 }
            return props.testSuites.count
        }()

        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short

        let ctx = ValidateContext(
            currentUser:  req.currentUserContext,
            assignmentID: idStr,
            setupID:      assignment.testSetupID,
            title:        assignment.title,
            suiteCount:   suiteCount,
            dueAt:        assignment.dueAt.map { fmt.string(from: $0) }
        )
        return try await req.view.render("assignment-validate", ctx)
    }

    // MARK: - POST /assignments/:assignmentID/open

    @Sendable
    func openAssignment(req: Request) async throws -> Response {
        guard
            let idStr      = req.parameters.get("assignmentID"),
            let uuid       = UUID(uuidString: idStr),
            let assignment = try await APIAssignment.find(uuid, on: req.db)
        else {
            throw Abort(.notFound)
        }
        assignment.isOpen = true
        try await assignment.save(on: req.db)
        return req.redirect(to: "/assignments")
    }

    // MARK: - POST /assignments/:assignmentID/close

    @Sendable
    func closeAssignment(req: Request) async throws -> Response {
        guard
            let idStr      = req.parameters.get("assignmentID"),
            let uuid       = UUID(uuidString: idStr),
            let assignment = try await APIAssignment.find(uuid, on: req.db)
        else {
            throw Abort(.notFound)
        }
        assignment.isOpen = false
        try await assignment.save(on: req.db)
        return req.redirect(to: "/assignments")
    }

    // MARK: - POST /assignments/:assignmentID/delete

    @Sendable
    func deleteAssignment(req: Request) async throws -> Response {
        guard
            let idStr      = req.parameters.get("assignmentID"),
            let uuid       = UUID(uuidString: idStr),
            let assignment = try await APIAssignment.find(uuid, on: req.db)
        else {
            throw Abort(.notFound)
        }
        try await assignment.delete(on: req.db)
        return req.redirect(to: "/assignments")
    }

    // MARK: - GET /assignments/:assignmentID/edit  [Phase 8]
    // Instructor-only notebook editor — loads JupyterLite, allows saving edits
    // back to the server via PUT /api/v1/testsetups/:id/assignment.

    @Sendable
    func editPage(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        guard
            let idStr      = req.parameters.get("assignmentID"),
            let uuid       = UUID(uuidString: idStr),
            let assignment = try await APIAssignment.find(uuid, on: req.db),
            let setup      = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let ctx = EditContext(
            currentUser:  req.currentUserContext,
            assignmentID: idStr,
            setupID:      assignment.testSetupID,
            title:        assignment.title,
            notebookURL:  "/api/v1/testsetups/\(assignment.testSetupID)/assignment"
        )
        _ = setup   // referenced for the DB fetch; notebookPath resolved by getAssignment endpoint
        return try await req.view.render("setup-edit", ctx)
    }
}

// MARK: - View context types

struct AssignmentRow: Encodable {
    let setupID:      String
    let assignmentID: String?   // nil if unpublished
    let title:        String?   // nil if unpublished
    let isOpen:       Bool?     // nil if unpublished
    let dueAt:        String?
    let status:       String    // "unpublished" | "open" | "closed"
    let suiteCount:   Int
    let createdAt:    String
}

private struct AssignmentsContext: Encodable {
    let currentUser: CurrentUserContext?
    let rows: [AssignmentRow]
}

private struct ValidateContext: Encodable {
    let currentUser:  CurrentUserContext?
    let assignmentID: String
    let setupID:      String
    let title:        String
    let suiteCount:   Int
    let dueAt:        String?
}

private struct EditContext: Encodable {
    let currentUser:  CurrentUserContext?
    let assignmentID: String
    let setupID:      String
    let title:        String
    /// URL of the notebook JSON endpoint, passed to JupyterLite via `fromURL`.
    let notebookURL:  String
}
