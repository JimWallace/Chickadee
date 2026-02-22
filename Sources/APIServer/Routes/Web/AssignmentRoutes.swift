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
            let validationStatus = assignment?.validationStatus ?? (assignment == nil ? "unpublished" : "passed")
            let validationSubmissionID = assignment?.validationSubmissionID

            return AssignmentRow(
                setupID:      setupID,
                assignmentID: assignment?.id?.uuidString,
                title:        assignment?.title,
                isOpen:       assignment?.isOpen,
                dueAt:        assignment?.dueAt.map { fmt.string(from: $0) },
                status:       status,
                validationStatus: validationStatus,
                validationSubmissionID: validationSubmissionID,
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
        struct NewQuery: Content {
            var assignmentName: String?
            var dueAt: String?
            var error: String?
            var notice: String?
        }
        let q = (try? req.query.decode(NewQuery.self))
        let ctx = NewAssignmentContext(
            currentUser: req.currentUserContext,
            assignmentName: (q?.assignmentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            dueAt: q?.dueAt ?? "",
            notice: q?.notice,
            error: q?.error
        )
        return try await req.view.render("assignment-new", ctx)
    }

    // MARK: - GET /assignments/new/details

    @Sendable
    func newAssignmentDetailsPage(req: Request) async throws -> Response {
        return req.redirect(to: "/assignments/new")
    }

    // MARK: - POST /assignments/new/save

    @Sendable
    func saveNewAssignment(req: Request) async throws -> Response {
        struct SaveBody: Content {
            var assignmentName: String?
            var dueAt: String?
            var assignmentNotebookFile: File?
            var solutionNotebookFile: File?
            var suiteFiles: [File]?
        }

        let body = try req.content.decode(SaveBody.self)
        let title = (body.assignmentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let due = parseDueDate(body.dueAt)

        guard !title.isEmpty else {
            let q = "assignmentName=&dueAt=\(urlEncode(body.dueAt ?? ""))&error=Assignment%20name%20is%20required"
            return req.redirect(to: "/assignments/new?\(q)")
        }

        guard let assignmentNotebookFile = body.assignmentNotebookFile,
              assignmentNotebookFile.data.readableBytes > 0 else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(body.dueAt ?? ""))&error=Assignment%20notebook%20(.ipynb)%20is%20required"
            return req.redirect(to: "/assignments/new?\(q)")
        }
        guard let solutionNotebookFile = body.solutionNotebookFile,
              solutionNotebookFile.data.readableBytes > 0 else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(body.dueAt ?? ""))&error=Solution%20notebook%20(.ipynb)%20is%20required"
            return req.redirect(to: "/assignments/new?\(q)")
        }
        let suiteFiles = (body.suiteFiles ?? []).filter { $0.data.readableBytes > 0 }
        guard !suiteFiles.isEmpty else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(body.dueAt ?? ""))&error=At%20least%20one%20test%20suite%20file%20is%20required"
            return req.redirect(to: "/assignments/new?\(q)")
        }

        let assignmentNotebookRaw = Data(assignmentNotebookFile.data.readableBytesView)
        let solutionNotebookRaw = Data(solutionNotebookFile.data.readableBytesView)
        guard (try? JSONSerialization.jsonObject(with: assignmentNotebookRaw)) != nil else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(body.dueAt ?? ""))&error=Assignment%20notebook%20is%20not%20valid%20JSON%20(.ipynb)"
            return req.redirect(to: "/assignments/new?\(q)")
        }
        guard (try? JSONSerialization.jsonObject(with: solutionNotebookRaw)) != nil else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(body.dueAt ?? ""))&error=Solution%20notebook%20is%20not%20valid%20JSON%20(.ipynb)"
            return req.redirect(to: "/assignments/new?\(q)")
        }

        let assignmentNotebook = normalizeNotebookForJupyterLite(assignmentNotebookRaw)

        let setupID = "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let setupsDir = req.application.testSetupsDirectory
        let notebookPath = setupsDir + "\(setupID).ipynb"
        let zipPath = setupsDir + "\(setupID).zip"
        try assignmentNotebook.write(to: URL(fileURLWithPath: notebookPath))
        let suiteScripts = try createRunnerSetupZip(
            assignmentNotebookData: assignmentNotebook,
            suiteFiles: suiteFiles,
            zipPath: zipPath
        )
        guard !suiteScripts.isEmpty else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(body.dueAt ?? ""))&error=No%20test%20scripts%20(.sh)%20found%20in%20test%20suite"
            return req.redirect(to: "/assignments/new?\(q)")
        }

        let manifest = try makeWorkerManifestJSON(scripts: suiteScripts)
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
            isOpen: false,
            validationStatus: "pending",
            validationSubmissionID: nil
        )
        try await assignment.save(on: req.db)

        let validationSubmissionID = try await enqueueRunnerValidationSubmission(
            req: req,
            setupID: setupID,
            solutionNotebookData: normalizeNotebookForJupyterLite(solutionNotebookRaw)
        )
        assignment.validationSubmissionID = validationSubmissionID
        try await assignment.save(on: req.db)

        await ensureValidationRunnerAvailability(req: req)
        let validation = try await waitForRunnerValidation(req: req, submissionID: validationSubmissionID)
        switch validation {
        case .passed(let summary):
            assignment.validationStatus = "passed"
            try await assignment.save(on: req.db)
            let q = "notice=\(urlEncode("Runner validation passed (\(summary)). You can now open the assignment from the dashboard."))"
            return req.redirect(to: "/assignments/new?\(q)")
        case .failed(let summary):
            assignment.validationStatus = "failed"
            try await assignment.save(on: req.db)
            let q = "notice=\(urlEncode("Assignment saved, but runner validation failed (\(summary)). Fix your solution/test suite and create a new assignment."))"
            return req.redirect(to: "/assignments/new?\(q)")
        case .timedOut:
            assignment.validationStatus = "pending"
            try await assignment.save(on: req.db)
            let q = "notice=\(urlEncode("Assignment saved and validation started. It is still pending; refresh the dashboard shortly."))"
            return req.redirect(to: "/assignments/new?\(q)")
        }
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
        guard assignment.validationStatus == nil || assignment.validationStatus == "passed" else {
            throw Abort(.badRequest, reason: "Assignment cannot be opened until runner validation passes.")
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
            guard assignment.validationStatus == nil || assignment.validationStatus == "passed" else {
                throw Abort(.badRequest, reason: "Assignment cannot be opened until runner validation passes.")
            }
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
    let validationStatus: String
    let validationSubmissionID: String?
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

private func createRunnerSetupZip(
    assignmentNotebookData: Data,
    suiteFiles: [File],
    zipPath: String
) throws -> [String] {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent("chickadee_runner_setup_\(UUID().uuidString)")
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }

    var seenNames: Set<String> = []
    for (index, file) in suiteFiles.enumerated() {
        let data = Data(file.data.readableBytesView)
        guard !data.isEmpty else { continue }
        let rawName = file.filename.isEmpty ? "suite-file-\(index + 1)" : file.filename
        let baseName = sanitizeSuiteFilename(rawName)
        let finalName: String
        if !seenNames.contains(baseName) {
            finalName = baseName
        } else {
            let ext = URL(fileURLWithPath: baseName).pathExtension
            let stem = (baseName as NSString).deletingPathExtension
            var suffix = 2
            var candidate = baseName
            while seenNames.contains(candidate) {
                candidate = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
                suffix += 1
            }
            finalName = candidate
        }
        seenNames.insert(finalName)
        try data.write(to: tempDir.appendingPathComponent(finalName))
    }

    let notebookURL = tempDir.appendingPathComponent("assignment.ipynb")
    try assignmentNotebookData.write(to: notebookURL)

    let discoveredScripts = discoverShellScripts(in: tempDir)
    guard !discoveredScripts.isEmpty else {
        throw Abort(.badRequest, reason: "Test suite must include at least one .sh script")
    }
    let scripts = try orderSuiteScripts(discoveredScripts)

    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = tempDir
    zip.arguments = ["-q", "-r", zipPath, "."]
    try zip.run()
    zip.waitUntilExit()
    guard zip.terminationStatus == 0 else {
        throw Abort(.internalServerError, reason: "Failed to package setup zip")
    }
    return scripts
}

private func sanitizeSuiteFilename(_ raw: String) -> String {
    var name = (raw as NSString).lastPathComponent
    if name.isEmpty { name = "suite-file" }
    name = name.replacingOccurrences(of: "/", with: "-")
    name = name.replacingOccurrences(of: "\\", with: "-")
    return name
}

private func discoverShellScripts(in directory: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var scripts: [String] = []
    for case let fileURL as URL in enumerator {
        guard fileURL.pathExtension == "sh" else { continue }
        let relative = fileURL.path.replacingOccurrences(of: directory.path + "/", with: "")
        scripts.append(relative)
    }
    return scripts.sorted()
}

private func orderSuiteScripts(_ scripts: [String]) throws -> [String] {
    struct Entry {
        let path: String
        let order: Int?
    }

    let entries = scripts.map { script -> Entry in
        let filename = (script as NSString).lastPathComponent
        let ns = filename as NSString
        let range = NSRange(location: 0, length: ns.length)
        let regex = try? NSRegularExpression(pattern: #"^([0-9]+)[_-].+\.sh$"#)
        guard let match = regex?.firstMatch(in: filename, options: [], range: range),
              match.numberOfRanges >= 2,
              let orderRange = Range(match.range(at: 1), in: filename),
              let order = Int(filename[orderRange]) else {
            return Entry(path: script, order: nil)
        }
        return Entry(path: script, order: order)
    }

    let hasOrdered = entries.contains { $0.order != nil }
    let hasUnordered = entries.contains { $0.order == nil }
    if hasOrdered && hasUnordered {
        throw Abort(
            .badRequest,
            reason: "When using numbered test scripts, every .sh script must start with an order prefix like 01_ or 02-."
        )
    }

    if hasOrdered {
        return entries
            .sorted { lhs, rhs in
                if lhs.order != rhs.order {
                    return (lhs.order ?? 0) < (rhs.order ?? 0)
                }
                return lhs.path < rhs.path
            }
            .map(\.path)
    }

    return scripts.sorted()
}

private func makeWorkerManifestJSON(scripts: [String]) throws -> String {
    let testSuites = scripts.map { ["tier": "public", "script": $0] }
    let manifest: [String: Any] = [
        "schemaVersion": 1,
        "gradingMode": "worker",
        "requiredFiles": [],
        "testSuites": testSuites,
        "timeLimitSeconds": 10,
        "makefile": NSNull()
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest)
    return String(data: data, encoding: .utf8) ?? "{}"
}

private func enqueueRunnerValidationSubmission(
    req: Request,
    setupID: String,
    solutionNotebookData: Data
) async throws -> String {
    let submissionsDir = req.application.submissionsDirectory
    let subID = "sub_\(UUID().uuidString.lowercased().prefix(8))"
    let filePath = submissionsDir + "\(subID).ipynb"
    try solutionNotebookData.write(to: URL(fileURLWithPath: filePath))

    let priorCount = try await APISubmission.query(on: req.db)
        .filter(\.$testSetupID == setupID)
        .count()

    let user = try req.auth.require(APIUser.self)
    let submission = APISubmission(
        id:            subID,
        testSetupID:   setupID,
        zipPath:       filePath,
        attemptNumber: priorCount + 1,
        filename:      "solution.ipynb",
        userID:        user.id
    )
    try await submission.save(on: req.db)
    return subID
}

private enum RunnerValidationOutcome {
    case passed(summary: String)
    case failed(summary: String)
    case timedOut
}

private func waitForRunnerValidation(
    req: Request,
    submissionID: String,
    timeoutSeconds: TimeInterval = 45
) async throws -> RunnerValidationOutcome {
    let started = Date()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    while Date().timeIntervalSince(started) < timeoutSeconds {
        guard let submission = try await APISubmission.find(submissionID, on: req.db) else {
            throw Abort(.notFound, reason: "Validation submission missing")
        }

        if submission.status == "complete" || submission.status == "failed" {
            guard let result = try await APIResult.query(on: req.db)
                .filter(\.$submissionID == submissionID)
                .sort(\.$receivedAt, .descending)
                .first(),
                  let data = result.collectionJSON.data(using: .utf8) else {
                return .failed(summary: "no result payload")
            }

            let collection = try decoder.decode(TestOutcomeCollection.self, from: data)
            let summary = "\(collection.passCount)/\(collection.totalTests) passed"
            let passed = collection.buildStatus == .passed &&
                collection.failCount == 0 &&
                collection.errorCount == 0 &&
                collection.timeoutCount == 0
            return passed ? .passed(summary: summary) : .failed(summary: summary)
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    return .timedOut
}

private func ensureValidationRunnerAvailability(req: Request) async {
    let enabled = await req.application.localRunnerAutoStartStore.isEnabled()
    guard enabled else { return }

    let hasRecentRunner = await req.application.workerActivityStore.hasRecentActivity(within: 20)
    guard !hasRecentRunner else { return }

    await req.application.localRunnerManager.ensureRunning(app: req.application, logger: req.logger)
    try? await Task.sleep(nanoseconds: 1_000_000_000)
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
