// APIServer/Routes/Web/AssignmentRoutes.swift
//
// Instructor-facing assignment management routes.
// Requires instructor or admin role (enforced by routes.swift).
//
//   GET  /assignments                        → assignments.leaf (all setups + status)
//   GET  /assignments/new                    → assignment-new.leaf
//   GET  /assignments/new/details            → assignment-new-details.leaf
//   POST /assignments/new/save               → save draft assignment, redirect to /assignments
//   POST /assignments                        → create draft assignment → redirect to validate
//   GET  /assignments/:assignmentID/validate → assignment-validate.leaf
//   GET  /assignments/:assignmentID/edit     → setup-edit.leaf (JupyterLite notebook editor) [Phase 8]
//   POST /assignments/:assignmentID/status   → set open/closed status → redirect to /assignments
//   POST /assignments/:assignmentID/open     → set isOpen=true → redirect to /assignments
//   POST /assignments/:assignmentID/close    → set isOpen=false → redirect to /assignments
//   POST /assignments/:assignmentID/delete   → remove assignment record → redirect to /assignments

import Vapor
import Fluent
import Core
import Foundation
import Crypto

struct AssignmentRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let r = routes.grouped("assignments")
        r.get(use: list)
        r.get("new", use: newAssignmentPage)
        r.get("new", "details", use: newAssignmentDetailsPage)
        r.post("new", "save", use: saveNewAssignment)
        r.post(use: publish)
        r.get(":assignmentID", "validate", use: validatePage)
        r.get(":assignmentID", "edit",     use: editPage)         // Phase 8
        r.post(":assignmentID", "status",  use: updateStatus)
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

    // MARK: - GET /assignments/new

    @Sendable
    func newAssignmentPage(req: Request) async throws -> View {
        let ctx = NewAssignmentContext(currentUser: req.currentUserContext)
        return try await req.view.render("assignment-new", ctx)
    }

    // MARK: - GET /assignments/new/details

    @Sendable
    func newAssignmentDetailsPage(req: Request) async throws -> View {
        struct NewDetailsQuery: Content {
            var gradingMode: String?
            var assignmentName: String?
            var dueAt: String?
            var notice: String?
            var error: String?
        }
        let query = try req.query.decode(NewDetailsQuery.self)
        let mode = (query.gradingMode == "server") ? "server" : "browser"
        let assignmentName = (query.assignmentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let dueAt = query.dueAt ?? ""
        let notice = query.notice
        let error = query.error

        let ctx = NewAssignmentDetailsContext(
            currentUser: req.currentUserContext,
            gradingMode: mode,
            requiresServerUpload: mode == "server",
            assignmentName: assignmentName,
            dueAt: dueAt,
            notice: notice,
            error: error
        )
        return try await req.view.render("assignment-new-details", ctx)
    }

    // MARK: - POST /assignments/new/save

    @Sendable
    func saveNewAssignment(req: Request) async throws -> Response {
        struct SaveBody: Content {
            var assignmentName: String?
            var dueAt: String?
            var gradingMode: String?
            var browserNotebookFile: File?
        }

        let body = try req.content.decode(SaveBody.self)
        let mode = (body.gradingMode == "server") ? "server" : "browser"
        let title = (body.assignmentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let due = parseDueDate(body.dueAt)

        guard !title.isEmpty else {
            let q = "gradingMode=\(mode)&assignmentName=&dueAt=\(body.dueAt ?? "")&error=Assignment%20name%20is%20required"
            return req.redirect(to: "/assignments/new/details?\(q)")
        }

        // Phase 1 of this wizard save path: browser mode only.
        guard mode == "browser" else {
            let q = "gradingMode=\(mode)&assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(body.dueAt ?? ""))&error=Server-tested%20save%20is%20not%20wired%20yet"
            return req.redirect(to: "/assignments/new/details?\(q)")
        }

        let notebookData: Data
        if let file = body.browserNotebookFile, file.data.readableBytes > 0 {
            notebookData = Data(file.data.readableBytesView)
        } else {
            notebookData = defaultNotebookData(title: title)
        }

        // Validate notebook JSON upfront.
        guard (try? JSONSerialization.jsonObject(with: notebookData)) != nil else {
            let q = "gradingMode=browser&assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(body.dueAt ?? ""))&error=Uploaded%20file%20is%20not%20valid%20JSON%20(.ipynb)"
            return req.redirect(to: "/assignments/new/details?\(q)")
        }

        let setupID = "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let setupsDir = req.application.testSetupsDirectory
        let notebookPath = setupsDir + "\(setupID).ipynb"
        let zipPath = setupsDir + "\(setupID).zip"
        let normalizedNotebook = normalizeNotebookForJupyterLite(notebookData)

        try normalizedNotebook.write(to: URL(fileURLWithPath: notebookPath))
        try createNotebookZip(notebookData: normalizedNotebook, zipPath: zipPath)

        let manifest = #"{"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#
        let setup = APITestSetup(
            id: setupID,
            manifest: manifest,
            zipPath: zipPath,
            notebookPath: notebookPath
        )
        try await setup.save(on: req.db)

        let assignment = APIAssignment(
            testSetupID: setupID,
            title: title,
            dueAt: due,
            isOpen: false
        )
        try await assignment.save(on: req.db)

        return req.redirect(to: "/assignments")
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

    // MARK: - POST /assignments/:assignmentID/status

    @Sendable
    func updateStatus(req: Request) async throws -> Response {
        struct StatusBody: Content {
            var status: String
        }

        guard
            let idStr      = req.parameters.get("assignmentID"),
            let uuid       = UUID(uuidString: idStr),
            let assignment = try await APIAssignment.find(uuid, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let body = try req.content.decode(StatusBody.self)
        switch body.status {
        case "open":
            assignment.isOpen = true
        case "closed":
            assignment.isOpen = false
        default:
            throw Abort(.badRequest, reason: "Unsupported status '\(body.status)'")
        }
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

        // Materialize notebook into all likely JupyterLite file roots.
        // Different entrypoints may resolve baseUrl differently and look under
        // /files, /jupyterlite/files, /jupyterlite/lab/files, or /jupyterlite/notebooks/files.
        let fileRoots = [
            req.application.directory.publicDirectory + "files/",
            req.application.directory.publicDirectory + "jupyterlite/files/",
            req.application.directory.publicDirectory + "jupyterlite/lab/files/",
            req.application.directory.publicDirectory + "jupyterlite/notebooks/files/"
        ]
        let nbData: Data
        do {
            nbData = try notebookData(for: setup)
        } catch {
            // Keep the editor reachable even if setup artifacts are temporarily missing.
            req.logger.warning("Falling back to default notebook for edit page: \(error)")
            nbData = normalizeNotebookForJupyterLite(defaultNotebookData(title: assignment.title))
        }
        let digest = SHA256.hash(data: nbData)
        let version = digest
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let jupyterLiteNotebookPath = "\(assignment.testSetupID)-assignment-\(version).ipynb"
        for root in fileRoots {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            try nbData.write(to: URL(fileURLWithPath: root + jupyterLiteNotebookPath))
        }
        let editorURL = "/jupyterlite/lab/index.html?workspace=\(assignment.testSetupID)&reset&path=\(jupyterLiteNotebookPath)"

        let ctx = EditContext(
            currentUser:  req.currentUserContext,
            assignmentID: idStr,
            setupID:      assignment.testSetupID,
            title:        assignment.title,
            editorURL:    editorURL,
            notebookURL:  "/api/v1/testsetups/\(assignment.testSetupID)/assignment"
        )
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

private struct NewAssignmentContext: Encodable {
    let currentUser: CurrentUserContext?
}

private struct NewAssignmentDetailsContext: Encodable {
    let currentUser: CurrentUserContext?
    let gradingMode: String
    let requiresServerUpload: Bool
    let assignmentName: String
    let dueAt: String
    let notice: String?
    let error: String?
}

private func parseDueDate(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }

    let iso = ISO8601DateFormatter()
    if let d = iso.date(from: raw) { return d }

    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
    return fmt.date(from: raw)
}

private func urlEncode(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
}

private func defaultNotebookData(title: String) -> Data {
    let safeTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
    let json = """
    {
      "cells": [
        {
          "cell_type": "markdown",
          "metadata": {},
          "source": ["# \(safeTitle)\\n", "\\n", "Write your assignment instructions here.\\n"]
        },
        {
          "cell_type": "code",
          "execution_count": null,
          "metadata": {},
          "outputs": [],
          "source": ["# Student solution starts here\\n"]
        }
      ],
      "metadata": {
        "kernelspec": {
          "display_name": "Python (Pyodide)",
          "language": "python",
          "name": "python"
        },
        "language_info": {
          "name": "python"
        }
      },
      "nbformat": 4,
      "nbformat_minor": 5
    }
    """
    return Data(json.utf8)
}

private func createNotebookZip(notebookData: Data, zipPath: String) throws {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent("chickadee_new_assignment_\(UUID().uuidString)")
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }

    let notebookURL = tempDir.appendingPathComponent("assignment.ipynb")
    try notebookData.write(to: notebookURL)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.arguments = ["-j", "-q", zipPath, notebookURL.path]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw Abort(.internalServerError, reason: "Failed to package notebook zip")
    }
}

private struct EditContext: Encodable {
    let currentUser:  CurrentUserContext?
    let assignmentID: String
    let setupID:      String
    let title:        String
    /// Fully qualified JupyterLite editor URL with workspace and notebook path.
    let editorURL:    String
    /// URL of the canonical notebook JSON endpoint used for save + validation.
    let notebookURL:  String
}
