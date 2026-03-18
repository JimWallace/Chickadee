// APIServer/Routes/Web/MarmosetImportRoutes.swift
//
// Marmoset export import routes (instructor+).
//
//   GET  /assignments/import-marmoset              — upload form
//   POST /assignments/import-marmoset              — process import
//   GET  /assignments/import-marmoset/canonical/:setupID
//                                                   — download stored canonical zip
//
// Both form routes accept an optional ?sectionID= / sectionID body field to
// place the imported assignment(s) into an existing section.
//
// Import rules:
//   - One assignment is created per project found in the export.
//   - test.properties is parsed to build a Chickadee TestProperties manifest.
//   - Makefile presence is detected from the inner zip, not from test.properties.
//   - Canonical zip is stored alongside the test setup for manual validation.
//   - Starter-files .ipynb (if present) becomes the JupyterLite notebook.
//   - requiredFiles is left empty — instructor fills it in after import.
//   - All assignments are created closed with validationStatus: nil.

import Vapor
import Fluent
import Core
import Foundation

struct MarmosetImportRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let r = routes.grouped("assignments", "import-marmoset")
        r.get(use: importForm)
        r.post(use: processImport)
    }

    // MARK: - GET /assignments/import-marmoset

    @Sendable
    func importForm(req: Request) async throws -> View {
        let caller = try req.auth.require(APIUser.self)
        guard caller.isInstructor else { throw Abort(.forbidden) }

        let courseState = try await req.resolveActiveCourse(for: caller)
        guard let course = courseState.active else {
            throw Abort(.badRequest, reason: "No active course selected.")
        }

        let sectionIDRaw = req.query[String.self, at: "sectionID"]

        struct ImportFormContext: Encodable {
            let currentUser: CurrentUserContext?
            let courseCode: String
            let courseName: String
            let sectionID: String?
            let error: String?
        }

        return try await req.view.render("marmoset-import", ImportFormContext(
            currentUser: req.currentUserContext,
            courseCode:  course.code,
            courseName:  course.name,
            sectionID:   sectionIDRaw,
            error:       req.query[String.self, at: "error"]
        ))
    }

    // MARK: - POST /assignments/import-marmoset

    @Sendable
    func processImport(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        guard caller.isInstructor else { throw Abort(.forbidden) }

        let courseState = try await req.resolveActiveCourse(for: caller)
        guard courseState.active != nil,
              let courseUUID = courseState.activeCourseUUID
        else {
            throw Abort(.badRequest, reason: "No active course selected.")
        }

        // ── 1. Receive uploaded zip + optional sectionID ───────────────

        struct MarmosetUpload: Content {
            let file: File
            let sectionID: String?
        }
        let upload = try req.content.decode(MarmosetUpload.self)
        var buffer = upload.file.data
        guard buffer.readableBytes > 0,
              let fileBytes = buffer.readBytes(length: buffer.readableBytes)
        else {
            throw Abort(.badRequest, reason: "Empty file uploaded")
        }

        let resolvedSectionID: UUID? = try await resolveSectionID(
            upload.sectionID, courseID: courseUUID, db: req.db)

        // ── 2. Save to temp file and extract ──────────────────────────

        let tmpZipPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("marmoset-import-\(UUID().uuidString).zip").path
        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marmoset-import-ex-\(UUID().uuidString)", isDirectory: true)

        defer {
            try? FileManager.default.removeItem(atPath: tmpZipPath)
            try? FileManager.default.removeItem(at: extractDir)
        }

        try Data(fileBytes).write(to: URL(fileURLWithPath: tmpZipPath))
        try await extractZipArchive(zipPath: tmpZipPath, into: extractDir)

        // ── 3. Parse projects ──────────────────────────────────────────

        let projectsDir: URL
        let projects: [MarmosetProject]
        do {
            (projectsDir, projects) = try parseMarmosetExport(from: extractDir)
        } catch {
            throw Abort(.badRequest, reason: "Failed to parse Marmoset export: \(error)")
        }

        guard !projects.isEmpty else {
            throw Abort(.badRequest, reason: "No projects found in the Marmoset export. Expected files named <n>-test-setup.zip.")
        }

        // ── 4. Import each project ─────────────────────────────────────

        for project in projects {
            let n = project.number
            let setupsDir = req.application.testSetupsDirectory
            let setupID   = "setup_\(UUID().uuidString.lowercased().prefix(8))"

            // ── 4a. Build the Chickadee test setup zip ─────────────────

            let innerZipPath = projectsDir.appendingPathComponent("\(n)-test-setup.zip").path
            guard FileManager.default.fileExists(atPath: innerZipPath) else { continue }

            let stagingDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("marmoset-staging-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: stagingDir) }

            try await extractZipArchive(zipPath: innerZipPath, into: stagingDir)

            // Remove Marmoset-specific files that have no place in Chickadee.
            // The Makefile (jupyter nbconvert) is redundant — the runner's
            // extractNotebooksToCode() handles .ipynb → .py/.R natively.
            for name in ["test.properties", "Makefile", "__MACOSX"] {
                try? FileManager.default.removeItem(
                    at: stagingDir.appendingPathComponent(name))
            }

            // ── 4b. Read canonical solution for validation (NOT injected into test setup zip) ──
            //
            // We intentionally do NOT add the canonical file to the test setup zip.
            // Test suites that use chickadee.py's load_submission_modules() scan the working
            // directory for all .py files; adding solution.<ext> here would create a duplicate
            // when the runner also places the validation submission in the same directory,
            // causing "Multiple definitions of '<func>' found" errors.

            var canonicalSolution: (data: Data, originalFilename: String)? = nil
            let canonicalSrcPath = projectsDir.appendingPathComponent("\(n)-canonical.zip").path
            if FileManager.default.fileExists(atPath: canonicalSrcPath),
               let solution = try? extractSolutionFromCanonicalZip(zipPath: canonicalSrcPath) {
                canonicalSolution = (data: solution.data, originalFilename: solution.originalFilename)
            }
            let hasCanonical = canonicalSolution != nil

            // ── 4c. Inject assignment.ipynb from starter files (if any) ─

            var notebookPath: String? = nil
            let starterZipPath = projectsDir.appendingPathComponent("\(n)-project-starter-files.zip").path
            if FileManager.default.fileExists(atPath: starterZipPath),
               let starterFilename = try? firstNotebookInZip(zipPath: starterZipPath),
               let starterData = try? extractNotebookFromZip(zipPath: starterZipPath,
                                                             filename: starterFilename) {
                let normalized = normalizeNotebookForJupyterLite(starterData)
                // Into the zip as assignment.ipynb (canonical name Chickadee uses).
                try normalized.write(to: stagingDir.appendingPathComponent("assignment.ipynb"))
                // Also persist to the notebooks/ directory so the JupyterLite route can serve it.
                let notebookDir = setupsDir + "notebooks/\(setupID)/"
                try FileManager.default.createDirectory(atPath: notebookDir,
                                                        withIntermediateDirectories: true)
                let nbPath = notebookDir + "assignment.ipynb"
                try normalized.write(to: URL(fileURLWithPath: nbPath))
                notebookPath = nbPath
            }

            // ── 4d. Create the Chickadee test setup zip ────────────────

            let setupZipPath = setupsDir + "\(setupID).zip"
            try await createZipArchive(sourceDir: stagingDir, outputPath: setupZipPath)

            // ── 4e. Build the manifest ─────────────────────────────────

            let manifestJSON: String
            do {
                manifestJSON = try convertToChickadeeManifest(project: project)
            } catch {
                req.logger.warning("Marmoset import: failed to build manifest for project \(n): \(error)")
                continue
            }

            let totalSuites = project.publicTests.count + project.releaseTests.count + project.secretTests.count
            guard totalSuites > 0 else {
                req.logger.warning("Marmoset import: project \(n) has no test cases, skipping")
                continue
            }

            // ── 4f. Save test setup to DB ──────────────────────────────

            let setup = APITestSetup(
                id: setupID,
                manifest: manifestJSON,
                zipPath: setupZipPath,
                notebookPath: notebookPath,
                courseID: courseUUID
            )
            try await setup.save(on: req.db)

            // ── 4g. Create assignment and enqueue validation ───────────

            let title = project.suggestedTitle ?? "Imported Assignment \(n)"
            let assignment = try await createAssignmentWithUniquePublicID(
                req: req,
                testSetupID: setupID,
                title: title,
                dueAt: nil,
                isOpen: false,
                sortOrder: try await nextAssignmentSortOrder(req: req),
                validationStatus: hasCanonical ? "pending" : nil,
                validationSubmissionID: nil,
                sectionID: resolvedSectionID,
                courseID: courseUUID
            )

            if let canonical = canonicalSolution {
                let validationSubID = try await enqueueRunnerValidationSubmission(
                    req: req, setupID: setupID, solutionNotebookData: canonical.data,
                    filename: canonical.originalFilename)
                assignment.validationSubmissionID = validationSubID
                try await assignment.save(on: req.db)
            }

            req.logger.info("Marmoset import: created assignment '\(title)' (setup \(setupID)) for course \(courseUUID)")
        }

        // ── 5. Kick the runner and redirect ───────────────────────────

        await ensureValidationRunnerAvailability(req: req)
        return req.redirect(to: "/assignments")
    }
}
