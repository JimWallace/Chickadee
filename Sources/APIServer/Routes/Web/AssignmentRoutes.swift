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
//   GET  /assignments/:assignmentID/edit     → assignment-edit.leaf
//   POST /assignments/:assignmentID/edit/save → update assignment content + validate
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
        r.get(":assignmentID", "edit",     use: editPage)
        r.post(":assignmentID", "edit", "save", use: saveEditedAssignment)
        r.get(":assignmentID", "files", "notebook", use: downloadCurrentNotebookFile)
        r.get(":assignmentID", "files", "solution", use: downloadCurrentSolutionFile)
        r.get(":assignmentID", "files", "item", use: downloadCurrentSetupItem)
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
        struct SaveBodyMany: Content {
            var assignmentName: String?
            var dueAt: String?
            var assignmentNotebookFile: File?
            var solutionNotebookFile: File?
            var suiteFiles: [File]?
            var suiteConfig: String?
        }
        struct SaveBodySingle: Content {
            var assignmentName: String?
            var dueAt: String?
            var assignmentNotebookFile: File?
            var solutionNotebookFile: File?
            var suiteFiles: File?
            var suiteConfig: String?
        }

        let bodyMany = try? req.content.decode(SaveBodyMany.self)
        let bodySingle = bodyMany == nil ? (try? req.content.decode(SaveBodySingle.self)) : nil
        guard bodyMany != nil || bodySingle != nil else {
            throw Abort(.badRequest, reason: "Invalid assignment upload payload")
        }

        let assignmentName = bodyMany?.assignmentName ?? bodySingle?.assignmentName
        let dueAtRaw = bodyMany?.dueAt ?? bodySingle?.dueAt
        let assignmentNotebookFile = bodyMany?.assignmentNotebookFile ?? bodySingle?.assignmentNotebookFile
        let solutionNotebookFile = bodyMany?.solutionNotebookFile ?? bodySingle?.solutionNotebookFile
        let suiteFilesRaw = bodyMany?.suiteFiles ?? (bodySingle?.suiteFiles.map { [$0] } ?? [])
        let suiteConfigRaw = bodyMany?.suiteConfig ?? bodySingle?.suiteConfig

        let title = (assignmentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let due = parseDueDate(dueAtRaw)

        guard !title.isEmpty else {
            let q = "assignmentName=&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Assignment%20name%20is%20required"
            return req.redirect(to: "/assignments/new?\(q)")
        }

        guard let assignmentNotebookFile,
              assignmentNotebookFile.data.readableBytes > 0 else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Assignment%20notebook%20(.ipynb)%20is%20required"
            return req.redirect(to: "/assignments/new?\(q)")
        }
        guard let solutionNotebookFile,
              solutionNotebookFile.data.readableBytes > 0 else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Solution%20notebook%20(.ipynb)%20is%20required"
            return req.redirect(to: "/assignments/new?\(q)")
        }
        let suiteFiles = suiteFilesRaw.filter { $0.data.readableBytes > 0 }
        guard !suiteFiles.isEmpty else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=At%20least%20one%20test%20suite%20file%20is%20required"
            return req.redirect(to: "/assignments/new?\(q)")
        }

        let assignmentNotebookRaw = Data(assignmentNotebookFile.data.readableBytesView)
        let solutionNotebookRaw = Data(solutionNotebookFile.data.readableBytesView)
        guard (try? JSONSerialization.jsonObject(with: assignmentNotebookRaw)) != nil else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Assignment%20notebook%20is%20not%20valid%20JSON%20(.ipynb)"
            return req.redirect(to: "/assignments/new?\(q)")
        }
        guard (try? JSONSerialization.jsonObject(with: solutionNotebookRaw)) != nil else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Solution%20notebook%20is%20not%20valid%20JSON%20(.ipynb)"
            return req.redirect(to: "/assignments/new?\(q)")
        }

        let assignmentNotebook = normalizeNotebookForJupyterLite(assignmentNotebookRaw)

        let setupID = "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let setupsDir = req.application.testSetupsDirectory
        let notebookFilename = notebookFilenameForStorage(
            uploadedName: assignmentNotebookFile.filename,
            fallback: "assignment.ipynb"
        )
        let notebookDir = setupsDir + "notebooks/\(setupID)/"
        try FileManager.default.createDirectory(atPath: notebookDir, withIntermediateDirectories: true)
        let notebookPath = notebookDir + notebookFilename
        let zipPath = setupsDir + "\(setupID).zip"
        try assignmentNotebook.write(to: URL(fileURLWithPath: notebookPath))
        let setupPackage = try createRunnerSetupZip(
            assignmentNotebookData: assignmentNotebook,
            solutionNotebookData: normalizeNotebookForJupyterLite(solutionNotebookRaw),
            suiteFiles: suiteFiles,
            suiteConfigJSON: suiteConfigRaw,
            zipPath: zipPath
        )
        guard !setupPackage.testSuites.isEmpty else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Select%20at%20least%20one%20test%20file%20in%20the%20suite%20list"
            return req.redirect(to: "/assignments/new?\(q)")
        }

        let manifest = try makeWorkerManifestJSON(
            testSuites: setupPackage.testSuites,
            includeMakefile: setupPackage.hasMakefile
        )
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
            req.logger.warning("Assignment validation failed for setup \(setupID): \(summary) (submission \(validationSubmissionID))")
            return req.redirect(to: "/submissions/\(validationSubmissionID)")
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
        let setupID = assignment.testSetupID

        // Delete related submissions and their result rows for this setup.
        let submissions = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .all()
        let submissionIDs = submissions.compactMap(\.id)
        if !submissionIDs.isEmpty {
            try await APIResult.query(on: req.db)
                .filter(\.$submissionID ~~ submissionIDs)
                .delete()
            try await APISubmission.query(on: req.db)
                .filter(\.$id ~~ submissionIDs)
                .delete()
        }

        // Delete setup artifacts and setup row so it disappears from the assignments list.
        if let setup = try await APITestSetup.find(setupID, on: req.db) {
            try? FileManager.default.removeItem(atPath: setup.zipPath)
            if let notebookPath = setup.notebookPath, !notebookPath.isEmpty {
                try? FileManager.default.removeItem(atPath: notebookPath)
            }
            removeMaterializedNotebookFiles(req: req, setupID: setupID)
            try await setup.delete(on: req.db)
        }

        try await assignment.delete(on: req.db)
        return req.redirect(to: "/assignments")
    }

    // MARK: - GET /assignments/:assignmentID/edit

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
        _ = setup // keep existence check explicit

        struct EditQuery: Content {
            var assignmentName: String?
            var dueAt: String?
            var error: String?
            var notice: String?
        }
        let q = try? req.query.decode(EditQuery.self)
        let hasKnownSolution = assignment.validationStatus == "passed"
            || assignment.validationSubmissionID != nil
        let currentFiles = currentSetupFiles(
            for: setup,
            assignmentID: idStr,
            hasValidationSolution: hasKnownSolution
        )
        let currentDueAt = dueAtLocalInputString(assignment.dueAt)
        let ctx = EditAssignmentContext(
            currentUser: req.currentUserContext,
            assignmentID: idStr,
            assignmentName: (q?.assignmentName ?? assignment.title).trimmingCharacters(in: .whitespacesAndNewlines),
            dueAt: q?.dueAt ?? currentDueAt,
            currentAssignmentFile: currentFiles.assignmentFile.name,
            currentAssignmentURL: currentFiles.assignmentFile.url,
            currentSolutionFile: currentFiles.solutionFile?.name,
            currentSolutionURL: currentFiles.solutionFile?.url,
            existingSuiteRows: currentFiles.existingSuiteRows,
            notice: q?.notice,
            error: q?.error
        )
        return try await req.view.render("assignment-edit", ctx)
    }

    // MARK: - GET /assignments/:assignmentID/files/notebook

    @Sendable
    func downloadCurrentNotebookFile(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        guard
            let idStr = req.parameters.get("assignmentID"),
            let uuid = UUID(uuidString: idStr),
            let assignment = try await APIAssignment.find(uuid, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let data = try notebookData(for: setup)
        let downloadName = currentSetupFiles(
            for: setup,
            assignmentID: idStr,
            hasValidationSolution: assignment.validationSubmissionID != nil
        ).assignmentFile.name
        return buildFileResponse(data: data, filename: downloadName)
    }

    // MARK: - GET /assignments/:assignmentID/files/item?name=<filename>

    @Sendable
    func downloadCurrentSetupItem(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        guard
            let idStr = req.parameters.get("assignmentID"),
            let uuid = UUID(uuidString: idStr),
            let assignment = try await APIAssignment.find(uuid, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        struct FileQuery: Content {
            let name: String
        }
        let q = try req.query.decode(FileQuery.self)
        let fileName = (q.name as NSString).lastPathComponent
        guard !fileName.isEmpty, fileName == q.name else {
            throw Abort(.badRequest, reason: "Invalid file name")
        }

        guard let data = extractZipEntry(zipPath: setup.zipPath, entryName: fileName) else {
            throw Abort(.notFound, reason: "File '\(fileName)' not found in setup")
        }
        return buildFileResponse(data: data, filename: fileName)
    }

    // MARK: - GET /assignments/:assignmentID/files/solution

    @Sendable
    func downloadCurrentSolutionFile(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        guard
            let idStr = req.parameters.get("assignmentID"),
            let uuid = UUID(uuidString: idStr),
            let assignment = try await APIAssignment.find(uuid, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        if let data = extractZipEntry(zipPath: setup.zipPath, entryName: "solution.ipynb") {
            return buildFileResponse(data: data, filename: "solution.ipynb")
        }

        if let validationID = assignment.validationSubmissionID,
           let validationSubmission = try await APISubmission.find(validationID, on: req.db),
           let data = try? Data(contentsOf: URL(fileURLWithPath: validationSubmission.zipPath)),
           !data.isEmpty {
            return buildFileResponse(data: data, filename: "solution.ipynb")
        }

        if let fallbackSubmission = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == assignment.testSetupID)
            .filter(\.$kind == APISubmission.Kind.validation)
            .filter(\.$filename == "solution.ipynb")
            .sort(\.$submittedAt, .descending)
            .first(),
           let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackSubmission.zipPath)),
           !data.isEmpty {
            return buildFileResponse(data: data, filename: "solution.ipynb")
        }

        throw Abort(.notFound, reason: "No solution notebook is available for this assignment yet")
    }

    // MARK: - POST /assignments/:assignmentID/edit/save

    @Sendable
    func saveEditedAssignment(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        guard
            let idStr = req.parameters.get("assignmentID"),
            let uuid = UUID(uuidString: idStr),
            let assignment = try await APIAssignment.find(uuid, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        struct SaveBodyMany: Content {
            var assignmentName: String?
            var dueAt: String?
            var assignmentNotebookFile: File?
            var solutionNotebookFile: File?
            var suiteFiles: [File]?
            var suiteConfig: String?
        }
        struct SaveBodySingle: Content {
            var assignmentName: String?
            var dueAt: String?
            var assignmentNotebookFile: File?
            var solutionNotebookFile: File?
            var suiteFiles: File?
            var suiteConfig: String?
        }

        let bodyMany = try? req.content.decode(SaveBodyMany.self)
        let bodySingle = bodyMany == nil ? (try? req.content.decode(SaveBodySingle.self)) : nil
        guard bodyMany != nil || bodySingle != nil else {
            throw Abort(.badRequest, reason: "Invalid assignment upload payload")
        }

        let assignmentName = bodyMany?.assignmentName ?? bodySingle?.assignmentName
        let dueAtRaw = bodyMany?.dueAt ?? bodySingle?.dueAt
        let assignmentNotebookFile = bodyMany?.assignmentNotebookFile ?? bodySingle?.assignmentNotebookFile
        let solutionNotebookFile = bodyMany?.solutionNotebookFile ?? bodySingle?.solutionNotebookFile
        let suiteFilesRaw = bodyMany?.suiteFiles ?? (bodySingle?.suiteFiles.map { [$0] } ?? [])
        let suiteConfigRaw = bodyMany?.suiteConfig ?? bodySingle?.suiteConfig

        let title = (assignmentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let due = parseDueDate(dueAtRaw)

        guard !title.isEmpty else {
            let q = "assignmentName=&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Assignment%20name%20is%20required"
            return req.redirect(to: "/assignments/\(idStr)/edit?\(q)")
        }

        let uploadedSuiteFiles = suiteFilesRaw.filter { $0.data.readableBytes > 0 }

        let hasUploadedAssignmentNotebook = assignmentNotebookFile?.data.readableBytes ?? 0 > 0
        let assignmentNotebookRaw: Data = {
            guard let assignmentNotebookFile, hasUploadedAssignmentNotebook else {
                return (try? notebookData(for: setup)) ?? Data()
            }
            return Data(assignmentNotebookFile.data.readableBytesView)
        }()
        guard !assignmentNotebookRaw.isEmpty,
              (try? JSONSerialization.jsonObject(with: assignmentNotebookRaw)) != nil else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Assignment%20notebook%20(.ipynb)%20is%20required%20and%20must%20be%20valid%20JSON"
            return req.redirect(to: "/assignments/\(idStr)/edit?\(q)")
        }

        let solutionNotebookRaw: Data = {
            if let solutionNotebookFile, solutionNotebookFile.data.readableBytes > 0 {
                return Data(solutionNotebookFile.data.readableBytesView)
            }
            return extractZipEntry(zipPath: setup.zipPath, entryName: "solution.ipynb") ?? Data()
        }()
        var resolvedSolutionNotebookRaw = solutionNotebookRaw
        if resolvedSolutionNotebookRaw.isEmpty,
           let existingSolution = try await loadExistingSolutionNotebook(req: req, assignment: assignment) {
            resolvedSolutionNotebookRaw = existingSolution
        }
        guard !resolvedSolutionNotebookRaw.isEmpty,
              (try? JSONSerialization.jsonObject(with: resolvedSolutionNotebookRaw)) != nil else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Solution%20notebook%20(.ipynb)%20is%20required%20for%20validation"
            return req.redirect(to: "/assignments/\(idStr)/edit?\(q)")
        }

        let resolvedSuite: ResolvedEditSuiteFiles
        do {
            resolvedSuite = try resolveEditSuiteFiles(
                setupZipPath: setup.zipPath,
                setupManifestJSON: setup.manifest,
                uploadedSuiteFiles: uploadedSuiteFiles,
                suiteConfigJSON: suiteConfigRaw
            )
        } catch {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=\(urlEncode(error.localizedDescription))"
            return req.redirect(to: "/assignments/\(idStr)/edit?\(q)")
        }
        guard !resolvedSuite.files.isEmpty else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Add%20or%20keep%20at%20least%20one%20test%20suite%20or%20support%20file"
            return req.redirect(to: "/assignments/\(idStr)/edit?\(q)")
        }

        let assignmentNotebook = normalizeNotebookForJupyterLite(assignmentNotebookRaw)
        let notebookPath: String = {
            if hasUploadedAssignmentNotebook {
                let fallbackName = setup.notebookPath
                    .map { URL(fileURLWithPath: $0).lastPathComponent }
                    .flatMap { $0.isEmpty ? nil : $0 }
                    ?? "assignment.ipynb"
                let uploadedName = assignmentNotebookFile?.filename
                let filename = notebookFilenameForStorage(uploadedName: uploadedName, fallback: fallbackName)
                let dir = req.application.testSetupsDirectory + "notebooks/\(setup.id!)/"
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                return dir + filename
            }
            return setup.notebookPath ?? (req.application.testSetupsDirectory + "\(setup.id!).ipynb")
        }()
        try assignmentNotebook.write(to: URL(fileURLWithPath: notebookPath))

        let setupPackage = try createRunnerSetupZip(
            assignmentNotebookData: assignmentNotebook,
            solutionNotebookData: normalizeNotebookForJupyterLite(resolvedSolutionNotebookRaw),
            suiteFiles: resolvedSuite.files,
            suiteConfigJSON: resolvedSuite.reindexedSuiteConfigJSON,
            zipPath: setup.zipPath
        )
        guard !setupPackage.testSuites.isEmpty else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Select%20at%20least%20one%20test%20file%20in%20the%20suite%20list"
            return req.redirect(to: "/assignments/\(idStr)/edit?\(q)")
        }
        setup.manifest = try makeWorkerManifestJSON(
            testSuites: setupPackage.testSuites,
            includeMakefile: setupPackage.hasMakefile
        )
        setup.notebookPath = notebookPath
        try await setup.save(on: req.db)

        assignment.title = title
        assignment.dueAt = due
        assignment.isOpen = false
        assignment.validationStatus = "pending"

        let validationSubmissionID = try await enqueueRunnerValidationSubmission(
            req: req,
            setupID: setup.id!,
            solutionNotebookData: normalizeNotebookForJupyterLite(resolvedSolutionNotebookRaw)
        )
        assignment.validationSubmissionID = validationSubmissionID
        try await assignment.save(on: req.db)

        await ensureValidationRunnerAvailability(req: req)
        let validation = try await waitForRunnerValidation(req: req, submissionID: validationSubmissionID)
        switch validation {
        case .passed(let summary):
            assignment.validationStatus = "passed"
            try await assignment.save(on: req.db)
            req.logger.info("Assignment updated and validated for setup \(setup.id ?? ""): \(summary)")
            return req.redirect(to: "/assignments")
        case .failed(let summary):
            assignment.validationStatus = "failed"
            try await assignment.save(on: req.db)
            req.logger.warning("Assignment edit validation failed for setup \(setup.id ?? ""): \(summary) (submission \(validationSubmissionID))")
            return req.redirect(to: "/submissions/\(validationSubmissionID)")
        case .timedOut:
            assignment.validationStatus = "pending"
            try await assignment.save(on: req.db)
            let q = "notice=\(urlEncode("Assignment updated and validation started. It is still pending; refresh shortly."))"
            return req.redirect(to: "/assignments/\(idStr)/edit?\(q)")
        }
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

private struct EditAssignmentContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentID: String
    let assignmentName: String
    let dueAt: String
    let currentAssignmentFile: String
    let currentAssignmentURL: String
    let currentSolutionFile: String?
    let currentSolutionURL: String?
    let existingSuiteRows: [EditableSuiteRow]
    let notice: String?
    let error: String?
}

private struct CurrentFileLink {
    let name: String
    let url: String
}

private struct EditableSuiteRow: Encodable {
    let name: String
    let url: String
    let isTest: Bool
    let tier: String
    let order: Int
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

private func dueAtLocalInputString(_ date: Date?) -> String {
    guard let date else { return "" }
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
    return fmt.string(from: date)
}

private func notebookFilenameForStorage(uploadedName: String?, fallback: String) -> String {
    var fileName = uploadedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if fileName.isEmpty {
        fileName = fallback
    }
    fileName = URL(fileURLWithPath: fileName).lastPathComponent
    fileName = fileName
        .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r"))
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if fileName.isEmpty {
        fileName = fallback
    }
    if !fileName.lowercased().hasSuffix(".ipynb") {
        fileName += ".ipynb"
    }
    return fileName
}

private func currentSetupFiles(for setup: APITestSetup, assignmentID: String, hasValidationSolution: Bool) -> (
    assignmentFile: CurrentFileLink,
    solutionFile: CurrentFileLink?,
    existingSuiteRows: [EditableSuiteRow]
) {
    let assignmentFile: CurrentFileLink = {
        let fileName: String
        if let path = setup.notebookPath, !path.isEmpty {
            fileName = URL(fileURLWithPath: path).lastPathComponent
        } else {
            fileName = "assignment.ipynb"
        }
        return CurrentFileLink(
            name: fileName,
            url: "/assignments/\(assignmentID)/files/notebook"
        )
    }()

    let manifestSuites: [(script: String, tier: String, order: Int)] = {
        guard let data = setup.manifest.data(using: .utf8),
              let props = try? JSONDecoder().decode(TestProperties.self, from: data) else {
            return []
        }
        return props.testSuites.enumerated().map { (idx, item) in
            (script: item.script, tier: item.tier.rawValue, order: idx + 1)
        }
    }()
    let testMap = Dictionary(uniqueKeysWithValues: manifestSuites.map { ($0.script, $0) })

    let archiveFiles = listZipEntries(zipPath: setup.zipPath)
    let solutionFile: CurrentFileLink? = {
        if archiveFiles.contains("solution.ipynb") {
            return CurrentFileLink(
                name: "solution.ipynb",
                url: "/assignments/\(assignmentID)/files/item?name=solution.ipynb"
            )
        }
        if hasValidationSolution {
            return CurrentFileLink(name: "solution.ipynb", url: "/assignments/\(assignmentID)/files/solution")
        }
        return nil
    }()

    let nonNotebookFiles = archiveFiles
        .filter { $0 != "assignment.ipynb" && $0 != "solution.ipynb" }
        .sorted { lhs, rhs in
            let l = testMap[lhs]?.order ?? Int.max
            let r = testMap[rhs]?.order ?? Int.max
            if l != r { return l < r }
            return lhs < rhs
        }

    let existingSuiteRows = nonNotebookFiles.enumerated().map { idx, name in
        let entry = testMap[name]
        return EditableSuiteRow(
            name: name,
            url: "/assignments/\(assignmentID)/files/item?name=\(urlEncode(name))",
            isTest: entry != nil,
            tier: entry?.tier ?? "support",
            order: entry?.order ?? (idx + 1)
        )
    }

    return (assignmentFile, solutionFile, existingSuiteRows)
}

private func listZipEntries(zipPath: String) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-Z1", zipPath]

    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return []
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return [] }
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    return text
        .split(separator: "\n")
        .map(String.init)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !$0.hasSuffix("/") }
}

private func extractZipEntry(zipPath: String, entryName: String) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", zipPath, entryName]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return data
}

private func buildFileResponse(data: Data, filename: String) -> Response {
    var headers = HTTPHeaders()
    headers.contentType = contentType(for: filename)
    headers.add(name: .contentDisposition, value: "attachment; filename=\"\(filename)\"")
    return Response(status: .ok, headers: headers, body: .init(data: data))
}

private func contentType(for filename: String) -> HTTPMediaType {
    switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
    case "ipynb", "json":
        return .json
    case "py", "sh", "bash", "zsh", "rb", "pl", "js", "php", "txt", "md", "csv":
        return .plainText
    default:
        return HTTPMediaType(type: "application", subType: "octet-stream")
    }
}

private struct EditSuiteConfigRow: Decodable {
    let source: String?
    let name: String?
    let index: Int?
    let isIncluded: Bool?
    let isTest: Bool?
    let tier: String?
    let order: Int?
}

private struct ReindexedSuiteConfigRow: Encodable {
    let index: Int
    let isTest: Bool
    let tier: String
    let order: Int?
}

private struct ResolvedEditSuiteFiles {
    let files: [File]
    let reindexedSuiteConfigJSON: String?
}

private func resolveEditSuiteFiles(
    setupZipPath: String,
    setupManifestJSON: String,
    uploadedSuiteFiles: [File],
    suiteConfigJSON: String?
) throws -> ResolvedEditSuiteFiles {
    let parsedRows: [EditSuiteConfigRow] = {
        guard let raw = suiteConfigJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let rows = try? JSONDecoder().decode([EditSuiteConfigRow].self, from: data) else {
            return []
        }
        return rows
    }()

    // Backward compatibility: no table config submitted.
    // Preserve existing suite/support files and append any new uploads.
    if parsedRows.isEmpty {
        let existingEntries = listZipEntries(zipPath: setupZipPath)
            .filter { $0 != "assignment.ipynb" && $0 != "solution.ipynb" }
            .sorted()

        var resolvedFiles: [File] = []
        var configRows: [ReindexedSuiteConfigRow] = []
        var nextOrder = 1

        let manifestTests: [String: (tier: String, order: Int)] = {
            guard let data = setupManifestJSON.data(using: .utf8),
                  let props = try? JSONDecoder().decode(TestProperties.self, from: data) else {
                return [:]
            }
            var map: [String: (tier: String, order: Int)] = [:]
            for (idx, entry) in props.testSuites.enumerated() {
                map[entry.script] = (entry.tier.rawValue, idx + 1)
            }
            return map
        }()

        for name in existingEntries {
            guard let data = extractZipEntry(zipPath: setupZipPath, entryName: name) else { continue }
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            resolvedFiles.append(File(data: buffer, filename: name))

            let testInfo = manifestTests[name]
            let tier = testInfo?.tier ?? "support"
            configRows.append(ReindexedSuiteConfigRow(
                index: resolvedFiles.count - 1,
                isTest: testInfo != nil && tier != "support",
                tier: tier,
                order: testInfo?.order ?? nextOrder
            ))
            nextOrder += 1
        }

        let appendedUploads = uploadedSuiteFiles.filter { $0.data.readableBytes > 0 }
        for (idx, file) in appendedUploads.enumerated() {
            let rawName = file.filename.isEmpty ? "suite-file-\(idx + 1)" : file.filename
            let cleanName = sanitizeSuiteFilename(rawName)
            let data = Data(file.data.readableBytesView)
            guard !data.isEmpty else { continue }
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            resolvedFiles.append(File(data: buffer, filename: cleanName))

            let ext = URL(fileURLWithPath: cleanName).pathExtension.lowercased()
            let likelyTest = ["sh","bash","zsh","py","rb","pl","js","php"].contains(ext)
            configRows.append(ReindexedSuiteConfigRow(
                index: resolvedFiles.count - 1,
                isTest: likelyTest,
                tier: likelyTest ? "public" : "support",
                order: nextOrder
            ))
            nextOrder += 1
        }

        let configJSON: String? = {
            guard let data = try? JSONEncoder().encode(configRows) else { return nil }
            return String(data: data, encoding: .utf8)
        }()
        return ResolvedEditSuiteFiles(
            files: resolvedFiles,
            reindexedSuiteConfigJSON: configJSON
        )
    }

    var resolvedFiles: [File] = []
    var configRows: [ReindexedSuiteConfigRow] = []
    var nextOrder = 1

    for row in parsedRows {
        let included = row.isIncluded ?? true
        guard included else { continue }

        let source = (row.source ?? "").lowercased()
        let dataAndName: (Data, String)?
        if source == "existing" {
            guard let rawName = row.name, !rawName.isEmpty else { continue }
            let cleanName = (rawName as NSString).lastPathComponent
            guard cleanName == rawName, !cleanName.isEmpty else { continue }
            guard let data = extractZipEntry(zipPath: setupZipPath, entryName: cleanName) else { continue }
            dataAndName = (data, cleanName)
        } else if source == "upload" {
            guard let idx = row.index, uploadedSuiteFiles.indices.contains(idx) else { continue }
            let file = uploadedSuiteFiles[idx]
            let data = Data(file.data.readableBytesView)
            guard !data.isEmpty else { continue }
            let rawName = file.filename.isEmpty ? "suite-file-\(idx + 1)" : file.filename
            dataAndName = (data, sanitizeSuiteFilename(rawName))
        } else {
            continue
        }

        guard let (data, name) = dataAndName else { continue }

        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        resolvedFiles.append(File(data: buffer, filename: name))

        let tier = normalizeTier(row.tier)
        let isTest = (row.isTest ?? false) && tier != "support"
        configRows.append(ReindexedSuiteConfigRow(
            index: resolvedFiles.count - 1,
            isTest: isTest,
            tier: tier,
            order: row.order ?? nextOrder
        ))
        nextOrder += 1
    }

    let configJSON: String? = {
        guard let data = try? JSONEncoder().encode(configRows) else { return nil }
        return String(data: data, encoding: .utf8)
    }()
    return ResolvedEditSuiteFiles(files: resolvedFiles, reindexedSuiteConfigJSON: configJSON)
}

private func loadExistingSolutionNotebook(req: Request, assignment: APIAssignment) async throws -> Data? {
    if let validationID = assignment.validationSubmissionID,
       let validationSubmission = try await APISubmission.find(validationID, on: req.db),
       let data = try? Data(contentsOf: URL(fileURLWithPath: validationSubmission.zipPath)),
       !data.isEmpty {
        return data
    }

    if let fallbackSubmission = try await APISubmission.query(on: req.db)
        .filter(\.$testSetupID == assignment.testSetupID)
        .filter(\.$kind == APISubmission.Kind.validation)
        .filter(\.$filename == "solution.ipynb")
        .sort(\.$submittedAt, .descending)
        .first(),
       let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackSubmission.zipPath)),
       !data.isEmpty {
        return data
    }

    return nil
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
    solutionNotebookData: Data?,
    suiteFiles: [File],
    suiteConfigJSON: String?,
    zipPath: String
) throws -> RunnerSetupPackage {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent("chickadee_runner_setup_\(UUID().uuidString)")
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }

    var seenNames: Set<String> = []
    var storedNameByIndex: [Int: String] = [:]
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
        storedNameByIndex[index] = finalName
    }

    let notebookURL = tempDir.appendingPathComponent("assignment.ipynb")
    try assignmentNotebookData.write(to: notebookURL)
    if let solutionNotebookData {
        let solutionURL = tempDir.appendingPathComponent("solution.ipynb")
        try solutionNotebookData.write(to: solutionURL)
    }

    let testSuites = try buildSuiteEntries(
        suiteFiles: suiteFiles,
        storedNameByIndex: storedNameByIndex,
        suiteConfigJSON: suiteConfigJSON
    )
    guard !testSuites.isEmpty else {
        throw Abort(.badRequest, reason: "Select at least one test file in the suite file list")
    }

    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = tempDir
    zip.arguments = ["-q", "-r", zipPath, "."]
    try zip.run()
    zip.waitUntilExit()
    guard zip.terminationStatus == 0 else {
        throw Abort(.internalServerError, reason: "Failed to package setup zip")
    }
    let hasMakefile = storedNameByIndex.values.contains {
        let n = $0.lowercased()
        return n == "makefile" || n == "gnumakefile"
    }
    return RunnerSetupPackage(testSuites: testSuites, hasMakefile: hasMakefile)
}

private func sanitizeSuiteFilename(_ raw: String) -> String {
    var name = (raw as NSString).lastPathComponent
    if name.isEmpty { name = "suite-file" }
    name = name.replacingOccurrences(of: "/", with: "-")
    name = name.replacingOccurrences(of: "\\", with: "-")
    return name
}

private struct SuiteConfigRow: Decodable {
    let index: Int
    let isTest: Bool
    let tier: String?
    let order: Int?
}

private struct ConfiguredSuiteEntry {
    let script: String
    let tier: String
    let order: Int
}

private struct RunnerSetupPackage {
    let testSuites: [ConfiguredSuiteEntry]
    let hasMakefile: Bool
}

private func buildSuiteEntries(
    suiteFiles: [File],
    storedNameByIndex: [Int: String],
    suiteConfigJSON: String?
) throws -> [ConfiguredSuiteEntry] {
    let parsedRows: [SuiteConfigRow] = {
        guard let raw = suiteConfigJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let rows = try? JSONDecoder().decode([SuiteConfigRow].self, from: data) else {
            return []
        }
        return rows
    }()

    if !parsedRows.isEmpty {
        var rowsByIndex: [Int: SuiteConfigRow] = [:]
        for row in parsedRows {
            rowsByIndex[row.index] = row
        }
        var selected: [ConfiguredSuiteEntry] = []
        for index in suiteFiles.indices {
            guard let row = rowsByIndex[index], row.isTest else { continue }
            guard let script = storedNameByIndex[index], !script.isEmpty else { continue }
            let tier = normalizeTier(row.tier)
            selected.append(ConfiguredSuiteEntry(
                script: script,
                tier: tier,
                order: row.order ?? (index + 1)
            ))
        }
        return selected
            .sorted { lhs, rhs in
                if lhs.order != rhs.order { return lhs.order < rhs.order }
                return lhs.script < rhs.script
            }
    }

    // Backward-compatible fallback when no suite config JSON is submitted.
    let supportedExtensions: Set<String> = ["sh", "bash", "zsh", "py", "rb", "pl", "js", "php"]
    var defaults: [ConfiguredSuiteEntry] = []
    for index in suiteFiles.indices {
        guard let script = storedNameByIndex[index], !script.isEmpty else { continue }
        let ext = URL(fileURLWithPath: script).pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { continue }
        defaults.append(ConfiguredSuiteEntry(
            script: script,
            tier: "public",
            order: inferredOrder(from: script) ?? (index + 1)
        ))
    }
    return defaults
        .sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.script < rhs.script
        }
}

private func inferredOrder(from filename: String) -> Int? {
    let base = (filename as NSString).lastPathComponent
    let ns = base as NSString
    let range = NSRange(location: 0, length: ns.length)
    let regex = try? NSRegularExpression(pattern: #"^([0-9]+)[_-].+$"#)
    guard let match = regex?.firstMatch(in: base, options: [], range: range),
          match.numberOfRanges >= 2,
          let orderRange = Range(match.range(at: 1), in: base) else {
        return nil
    }
    return Int(base[orderRange])
}

private func normalizeTier(_ raw: String?) -> String {
    switch (raw ?? "public").lowercased() {
    case "secret": return "secret"
    case "release": return "release"
    case "student": return "student"
    default: return "public"
    }
}

private func makeWorkerManifestJSON(
    testSuites: [ConfiguredSuiteEntry],
    includeMakefile: Bool
) throws -> String {
    let testSuiteJSON = testSuites.map { ["tier": $0.tier, "script": $0.script] }
    let manifest: [String: Any] = [
        "schemaVersion": 1,
        "gradingMode": "worker",
        "requiredFiles": [],
        "testSuites": testSuiteJSON,
        "timeLimitSeconds": 10,
        "makefile": includeMakefile ? ["target": NSNull()] : NSNull()
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
        .filter(\.$kind == APISubmission.Kind.validation)
        .count()

    let user = try req.auth.require(APIUser.self)
    let submission = APISubmission(
        id:            subID,
        testSetupID:   setupID,
        zipPath:       filePath,
        attemptNumber: priorCount + 1,
        filename:      "solution.ipynb",
        userID:        user.id,
        kind:          APISubmission.Kind.validation
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
        guard let submission = try await APISubmission.find(submissionID, on: req.db),
              submission.kind == APISubmission.Kind.validation else {
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

private func removeMaterializedNotebookFiles(req: Request, setupID: String) {
    let roots = [
        req.application.directory.publicDirectory + "files/",
        req.application.directory.publicDirectory + "jupyterlite/files/",
        req.application.directory.publicDirectory + "jupyterlite/lab/files/",
        req.application.directory.publicDirectory + "jupyterlite/notebooks/files/"
    ]
    for root in roots {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
        for name in entries where name.hasPrefix(setupID) && name.hasSuffix(".ipynb") {
            try? FileManager.default.removeItem(atPath: root + name)
        }
    }
}
