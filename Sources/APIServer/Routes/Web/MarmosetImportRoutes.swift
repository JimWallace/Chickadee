// APIServer/Routes/Web/MarmosetImportRoutes.swift
//
// Marmoset export import routes (admin only).
//
//   GET  /admin/courses/:courseID/import-marmoset              — upload form
//   POST /admin/courses/:courseID/import-marmoset              — process import
//   GET  /admin/courses/:courseID/import-marmoset/canonical/:setupID
//                                                               — download stored canonical zip
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
        let r = routes.grouped("admin", "courses", ":courseID", "import-marmoset")
        r.get(use: importForm)
        r.post(use: processImport)
        r.get("canonical", ":setupID", use: downloadCanonical)
    }

    // MARK: - GET /admin/courses/:courseID/import-marmoset

    @Sendable
    func importForm(req: Request) async throws -> View {
        let caller = try req.auth.require(APIUser.self)
        guard caller.isAdmin else { throw Abort(.forbidden) }

        guard let courseIDStr = req.parameters.get("courseID"),
              let courseUUID  = UUID(uuidString: courseIDStr),
              let course      = try await APICourse.find(courseUUID, on: req.db)
        else { throw Abort(.notFound, reason: "Course not found") }

        struct ImportFormContext: Encodable {
            let currentUser: CurrentUserContext?
            let courseID: String
            let courseCode: String
            let courseName: String
            let error: String?
        }

        let errorMsg = req.query[String.self, at: "error"]
        return try await req.view.render("marmoset-import", ImportFormContext(
            currentUser: req.currentUserContext,
            courseID:    courseIDStr,
            courseCode:  course.code,
            courseName:  course.name,
            error:       errorMsg
        ))
    }

    // MARK: - POST /admin/courses/:courseID/import-marmoset

    @Sendable
    func processImport(req: Request) async throws -> View {
        let caller = try req.auth.require(APIUser.self)
        guard caller.isAdmin else { throw Abort(.forbidden) }

        guard let courseIDStr = req.parameters.get("courseID"),
              let courseUUID  = UUID(uuidString: courseIDStr),
              let course      = try await APICourse.find(courseUUID, on: req.db)
        else { throw Abort(.notFound, reason: "Course not found") }

        // ── 1. Receive uploaded zip ────────────────────────────────────

        struct MarmosetUpload: Content {
            let file: File
        }
        let upload = try req.content.decode(MarmosetUpload.self)
        var buffer = upload.file.data
        guard buffer.readableBytes > 0,
              let fileBytes = buffer.readBytes(length: buffer.readableBytes)
        else {
            throw Abort(.badRequest, reason: "Empty file uploaded")
        }

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

        let projects: [MarmosetProject]
        do {
            projects = try parseMarmosetExport(from: extractDir)
        } catch {
            throw Abort(.badRequest, reason: "Failed to parse Marmoset export: \(error)")
        }

        guard !projects.isEmpty else {
            throw Abort(.badRequest, reason: "No projects found in the Marmoset export. Expected files named <n>-test-setup.zip.")
        }

        // ── 4. Import each project ─────────────────────────────────────

        var imported: [ImportedAssignment] = []

        for project in projects {
            let n = project.number
            let setupsDir = req.application.testSetupsDirectory
            let setupID   = "setup_\(UUID().uuidString.lowercased().prefix(8))"

            // ── 4a. Build the Chickadee test setup zip ─────────────────

            let innerZipPath = extractDir.appendingPathComponent("\(n)-test-setup.zip").path
            guard FileManager.default.fileExists(atPath: innerZipPath) else { continue }

            let stagingDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("marmoset-staging-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: stagingDir) }

            try await extractZipArchive(zipPath: innerZipPath, into: stagingDir)

            // Remove Marmoset-specific files that have no place in Chickadee.
            let filesToRemove = ["test.properties"]
            for name in filesToRemove {
                let path = stagingDir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: path)
            }
            // Remove __MACOSX resource fork directory if present.
            let macosx = stagingDir.appendingPathComponent("__MACOSX")
            try? FileManager.default.removeItem(at: macosx)

            let setupZipPath = setupsDir + "\(setupID).zip"
            try await createZipArchive(sourceDir: stagingDir, outputPath: setupZipPath)

            // ── 4b. Build the manifest ─────────────────────────────────

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

            // ── 4c. Store the canonical zip ────────────────────────────

            var hasCanonical = false
            let canonicalSrcPath = extractDir.appendingPathComponent("\(n)-canonical.zip").path
            if FileManager.default.fileExists(atPath: canonicalSrcPath) {
                let canonicalDstPath = setupsDir + "\(setupID)-canonical.zip"
                try? FileManager.default.copyItem(
                    atPath: canonicalSrcPath,
                    toPath: canonicalDstPath
                )
                hasCanonical = FileManager.default.fileExists(atPath: canonicalDstPath)
            }

            // ── 4d. Extract starter notebook (if any) ─────────────────

            var notebookPath: String? = nil
            let starterZipPath = extractDir.appendingPathComponent("\(n)-project-starter-files.zip").path
            if FileManager.default.fileExists(atPath: starterZipPath),
               let notebookFilename = try? firstNotebookInZip(zipPath: starterZipPath),
               let notebookData = try? extractNotebookFromZip(zipPath: starterZipPath, filename: notebookFilename) {
                let normalized = normalizeNotebookForJupyterLite(notebookData)
                let notebookDir = setupsDir + "notebooks/\(setupID)/"
                try FileManager.default.createDirectory(atPath: notebookDir,
                                                        withIntermediateDirectories: true)
                let nbPath = notebookDir + notebookFilename
                try normalized.write(to: URL(fileURLWithPath: nbPath))
                notebookPath = nbPath
            }

            // ── 4e. Save test setup to DB ──────────────────────────────

            let setup = APITestSetup(
                id: setupID,
                manifest: manifestJSON,
                zipPath: setupZipPath,
                notebookPath: notebookPath,
                courseID: courseUUID
            )
            try await setup.save(on: req.db)

            // ── 4f. Create the assignment ──────────────────────────────

            let title = project.suggestedTitle ?? "Imported Assignment \(n)"
            let assignment = try await createAssignmentWithUniquePublicID(
                req: req,
                testSetupID: setupID,
                title: title,
                dueAt: nil,
                isOpen: false,
                sortOrder: try await nextAssignmentSortOrder(req: req),
                validationStatus: nil,
                validationSubmissionID: nil,
                sectionID: nil,
                courseID: courseUUID
            )

            imported.append(ImportedAssignment(
                title:        title,
                publicID:     assignment.publicID,
                setupID:      setupID,
                suiteCount:   totalSuites,
                hasCanonical: hasCanonical,
                hasNotebook:  notebookPath != nil
            ))

            req.logger.info("Marmoset import: created assignment '\(title)' (setup \(setupID)) for course \(courseUUID)")
        }

        // ── 5. Render result page ──────────────────────────────────────

        struct ResultContext: Encodable {
            let currentUser: CurrentUserContext?
            let courseID: String
            let courseCode: String
            let courseName: String
            let assignments: [ImportedAssignment]
        }

        return try await req.view.render("marmoset-import-result", ResultContext(
            currentUser:  req.currentUserContext,
            courseID:     courseIDStr,
            courseCode:   course.code,
            courseName:   course.name,
            assignments:  imported
        ))
    }

    // MARK: - GET /admin/courses/:courseID/import-marmoset/canonical/:setupID

    @Sendable
    func downloadCanonical(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        guard caller.isAdmin else { throw Abort(.forbidden) }

        guard let courseIDStr = req.parameters.get("courseID"),
              let courseUUID  = UUID(uuidString: courseIDStr)
        else { throw Abort(.badRequest) }

        guard let setupID = req.parameters.get("setupID"),
              setupID.hasPrefix("setup_")
        else { throw Abort(.badRequest) }

        // Verify the test setup belongs to this course.
        guard let setup = try await APITestSetup.find(setupID, on: req.db),
              setup.courseID == courseUUID
        else { throw Abort(.notFound) }

        let canonicalPath = req.application.testSetupsDirectory + "\(setupID)-canonical.zip"
        guard FileManager.default.fileExists(atPath: canonicalPath),
              let zipData = try? Data(contentsOf: URL(fileURLWithPath: canonicalPath))
        else { throw Abort(.notFound, reason: "Canonical zip not found") }

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/zip")
        headers.add(name: .contentDisposition,
                    value: "attachment; filename=\"\(setupID)-canonical.zip\"")
        headers.add(name: .contentLength, value: "\(zipData.count)")
        return Response(status: .ok, headers: headers, body: .init(data: zipData))
    }
}

// MARK: - Supporting types

struct ImportedAssignment: Encodable, Sendable {
    let title: String
    let publicID: String
    let setupID: String
    let suiteCount: Int
    let hasCanonical: Bool
    let hasNotebook: Bool
}
