// APIServer/Routes/Web/MarmosetImportRoutes.swift
//
// Marmoset export import routes (instructor+).
//
//   GET  /instructor/import-marmoset              — upload form
//   POST /instructor/import-marmoset              — process import
//   GET  /instructor/import-marmoset/canonical/:setupID
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

import Core
import Fluent
import Foundation
import Vapor

struct MarmosetImportRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let r = routes.grouped("instructor", "import-marmoset")
        r.get(use: importForm)
        r.post(use: processImport)
    }

    // MARK: - GET /instructor/import-marmoset

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

        return try await req.view.render(
            "marmoset-import",
            ImportFormContext(
                currentUser: req.currentUserContext,
                courseCode: course.code,
                courseName: course.name,
                sectionID: sectionIDRaw,
                error: req.query[String.self, at: "error"]
            ))
    }

    // MARK: - POST /instructor/import-marmoset

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
            throw Abort(
                .badRequest,
                reason: "No projects found in the Marmoset export. Expected files named <n>-test-setup.zip.")
        }

        // ── 4. Import each project ─────────────────────────────────────

        for project in projects {
            try await importMarmosetProject(
                req: req,
                project: project,
                projectsDir: projectsDir,
                courseUUID: courseUUID,
                resolvedSectionID: resolvedSectionID
            )
        }

        // ── 5. Kick the runner and redirect ───────────────────────────

        await ensureValidationRunnerAvailability(req: req)
        return req.redirect(to: "/instructor")
    }

    // MARK: - Per-project helpers

    /// Imports a single Marmoset project: extracts the inner test-setup zip,
    /// builds the Chickadee test setup + manifest, persists the assignment
    /// and (if a canonical solution exists) enqueues a validation
    /// submission.  No-op silently if required files are missing or
    /// project has no test cases.
    private func importMarmosetProject(
        req: Request,
        project: MarmosetProject,
        projectsDir: URL,
        courseUUID: UUID,
        resolvedSectionID: UUID?
    ) async throws {
        let n = project.number
        let setupsDir = req.application.testSetupsDirectory
        let setupID = "setup_\(UUID().uuidString.lowercased().prefix(8))"

        // ── 4a. Build the Chickadee test setup zip ─────────────────

        let innerZipPath = projectsDir.appendingPathComponent("\(n)-test-setup.zip").path
        guard FileManager.default.fileExists(atPath: innerZipPath) else { return }

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

        let canonicalSolution = readCanonicalSolution(
            projectsDir: projectsDir, projectNumber: n)
        let hasCanonical = canonicalSolution != nil

        // ── 4c. Persist starter notebook from starter files (if any) ─

        let notebookPath = try persistStarterNotebook(
            projectsDir: projectsDir,
            projectNumber: n,
            setupsDir: setupsDir,
            setupID: setupID
        )

        // ── 4d. Create the Chickadee test setup zip ────────────────

        let setupZipPath = setupsDir + "\(setupID).zip"
        try await createZipArchive(sourceDir: stagingDir, outputPath: setupZipPath)

        // ── 4e. Build the manifest ─────────────────────────────────

        let manifestJSON: String
        do {
            manifestJSON = try convertToChickadeeManifest(project: project)
        } catch {
            req.logger.warning("Marmoset import: failed to build manifest for project \(n): \(error)")
            return
        }

        let totalSuites = project.publicTests.count + project.releaseTests.count + project.secretTests.count
        guard totalSuites > 0 else {
            req.logger.warning("Marmoset import: project \(n) has no test cases, skipping")
            return
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

        req.logger.info(
            "Marmoset import: created assignment '\(title)' (setup \(setupID)) for course \(courseUUID)")
    }

    /// Reads the per-project canonical-solution zip if present, returning
    /// the extracted solution bytes and its original filename for later
    /// validation enqueue.  Nil if the file is missing or unreadable.
    private func readCanonicalSolution(
        projectsDir: URL, projectNumber n: Int
    ) -> (data: Data, originalFilename: String)? {
        let canonicalSrcPath = projectsDir.appendingPathComponent("\(n)-canonical.zip").path
        guard FileManager.default.fileExists(atPath: canonicalSrcPath),
            let solution = try? extractSolutionFromCanonicalZip(zipPath: canonicalSrcPath)
        else { return nil }
        return (data: solution.data, originalFilename: solution.originalFilename)
    }

    /// Persists the starter notebook from a Marmoset starter-files zip if
    /// present (preserving the original Marmoset filename), otherwise
    /// writes a minimal blank notebook so the assignment is always
    /// openable.  Returns the absolute notebook path stored on the
    /// `APITestSetup`.
    ///
    /// The starter notebook is NOT included in the runner zip — the
    /// runner doesn't need it (the student provides their own file).
    /// It is only stored in notebooks/{setupID}/ for JupyterLite to
    /// serve to students.
    private func persistStarterNotebook(
        projectsDir: URL,
        projectNumber n: Int,
        setupsDir: String,
        setupID: String
    ) throws -> String {
        let notebookDir = setupsDir + "notebooks/\(setupID)/"
        let starterZipPath = projectsDir.appendingPathComponent("\(n)-project-starter-files.zip").path
        if FileManager.default.fileExists(atPath: starterZipPath),
            let starterFilename = try? firstNotebookInZip(zipPath: starterZipPath),
            let starterData = try? extractNotebookFromZip(
                zipPath: starterZipPath,
                filename: starterFilename)
        {
            let normalized = normalizeNotebookForJupyterLite(starterData)
            let storedName = notebookFilenameForStorage(
                uploadedName: starterFilename, fallback: "assignment.ipynb")
            try FileManager.default.createDirectory(
                atPath: notebookDir,
                withIntermediateDirectories: true)
            let nbPath = notebookDir + storedName
            try normalized.write(to: URL(fileURLWithPath: nbPath))
            return nbPath
        }
        // No starter-files zip — fall back to a minimal blank notebook so
        // the assignment is openable. Instructor can upload the real starter
        // via the assignment editor.
        try FileManager.default.createDirectory(
            atPath: notebookDir,
            withIntermediateDirectories: true)
        let nbPath = notebookDir + "assignment.ipynb"
        try minimalEmptyNotebookData().write(to: URL(fileURLWithPath: nbPath))
        return nbPath
    }
}
