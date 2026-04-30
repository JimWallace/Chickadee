// APIServer/Routes/Web/WebRoutes+Notebook.swift
//
// Notebook-related handlers and helpers for WebRoutes.
// Extracted from WebRoutes.swift — no behaviour changes.

import Vapor
import Fluent
import Core
import Foundation

enum NotebookFileKind: String {
    case assignment
    case solution
}

extension WebRoutes {

    // MARK: - GET /testsetups/:id/notebook

    @Sendable
    func notebookPage(req: Request) async throws -> View {
        struct NotebookQuery: Content {
            var title: String?
            var submissionID: String?
            var file: String?
        }
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.unauthorized) }
        guard
            let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        try await requireCourseEnrollment(caller: user, courseID: setup.courseID, db: req.db)

        let query = try req.query.decode(NotebookQuery.self)
        let fileKind = notebookFileKind(from: query.file)
        let queryTitle = (query.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let assignment = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .first()
        let dbTitle = (assignment?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let assignmentTitle = {
            if !queryTitle.isEmpty { return queryTitle }
            if !dbTitle.isEmpty { return dbTitle }
            return "Assignment"
        }()
        let requestedSubmissionID = (query.submissionID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let userSlug = userID.uuidString.lowercased()

        // --- Submission view (read-only) ---
        // Use a submission-specific working copy path and workspace ID so:
        //   1. The viewer's own assignment working copy is never overwritten.
        //   2. Each submission gets a fresh JupyterLite workspace; the browser
        //      IndexedDB cache from a previous visit to the edit/submit page
        //      cannot shadow the student's actual content.
        if !requestedSubmissionID.isEmpty {
            let notebookData = try await notebookDataForHistorySelection(
                req: req,
                caller: user,
                submissionID: requestedSubmissionID,
                setupID: setupID,
                userID: userID
            )
            let submissionRelativePath = "users/\(userSlug)/\(setupID)/view-\(requestedSubmissionID).ipynb"
            _ = try await ensureUserNotebookWorkingCopy(
                req: req,
                setupID: setupID,
                userID: userID,
                fallbackSetup: setup,
                relativePath: submissionRelativePath,
                overwriteWith: notebookData   // always overwrite — we want the exact submission
            )
            let encodedPath = submissionRelativePath
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                ?? submissionRelativePath
            let workspaceID = "\(setupID)-\(userSlug)-view-\(requestedSubmissionID)"
            let editorURL = "/jupyterlite/notebooks/index.html?workspace=\(workspaceID)&reset=1&path=\(encodedPath)"
            let notebookURL = "/testsetups/\(setupID)/notebook/source?submissionID=\(requestedSubmissionID)"
            let manifestGradingMode: String = {
                let data = Data(setup.manifest.utf8)
                guard let manifest = try? ManifestCodec.decoder.decode(TestProperties.self, from: data) else {
                    return GradingMode.browser.rawValue
                }
                return manifest.gradingMode.rawValue
            }()
            return try await req.view.render("notebook",
                NotebookContext(
                    testSetupID: setupID,
                    assignmentTitle: assignmentTitle,
                    notebookURL: notebookURL,
                    jupyterLiteEditorURL: editorURL,
                    downloadURL: nil,           // download link lives on the submission page
                    gradingMode: manifestGradingMode,
                    showSubmit: false,          // read-only view
                    currentUser: req.currentUserContext
                ))
        }

        // --- Normal assignment / solution view ---
        if fileKind == .solution {
            let solutionData = try await solutionNotebookData(for: assignment, setup: setup, db: req.db)
            _ = try await ensureUserNotebookWorkingCopy(
                req: req,
                setupID: setupID,
                userID: userID,
                fallbackSetup: setup,
                relativePath: userNotebookWorkingCopyRelativePath(setupID: setupID, userID: userID, fileKind: fileKind),
                defaultData: solutionData
            )
        } else {
            _ = try await ensureUserNotebookWorkingCopy(
                req: req,
                setupID: setupID,
                userID: userID,
                fallbackSetup: setup
            )
        }
        let jupyterLiteNotebookPath = userNotebookWorkingCopyRelativePath(setupID: setupID, userID: userID, fileKind: fileKind)
        let encodedPath = jupyterLiteNotebookPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? jupyterLiteNotebookPath
        let workspaceID = "\(setupID)-\(userSlug)-\(fileKind.rawValue)"
        let editorURL = "/jupyterlite/notebooks/index.html?workspace=\(workspaceID)&reset=&path=\(encodedPath)"
        let notebookURL = switch fileKind {
            case .assignment: "/testsetups/\(setupID)/notebook/source"
            case .solution:   "/testsetups/\(setupID)/notebook/source?file=solution"
        }
        let downloadURL: String? = {
            guard let assignment else { return nil }
            return switch fileKind {
                case .assignment: "/api/v1/testsetups/\(setupID)/assignment/download"
                case .solution:   "/instructor/\(assignment.publicID)/files/solution"
            }
        }()

        // Decode gradingMode from the manifest so the template can load
        // browser-runner.js for browser-graded assignments.
        let manifestGradingMode: String = {
            let data = Data(setup.manifest.utf8)
            guard let manifest = try? ManifestCodec.decoder.decode(TestProperties.self, from: data) else {
                return GradingMode.browser.rawValue
            }
            return manifest.gradingMode.rawValue
        }()

        return try await req.view.render("notebook",
            NotebookContext(
                testSetupID: setupID,
                assignmentTitle: assignmentTitle,
                notebookURL: notebookURL,
                jupyterLiteEditorURL: editorURL,
                downloadURL: downloadURL,
                gradingMode: manifestGradingMode,
                showSubmit: fileKind == .assignment,
                currentUser: req.currentUserContext
            ))
    }

    // MARK: - GET /testsetups/:id/notebook/source

    @Sendable
    func notebookSource(req: Request) async throws -> Response {
        struct NotebookSourceQuery: Content {
            var file: String?
            var submissionID: String?
        }
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.unauthorized) }
        guard
            let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        try await requireCourseEnrollment(caller: user, courseID: setup.courseID, db: req.db)

        let query = try req.query.decode(NotebookSourceQuery.self)

        // When serving a submission view, read from the submission-specific
        // working copy path that notebookPage already wrote to disk.
        if let submissionID = query.submissionID, !submissionID.isEmpty {
            let userSlug = userID.uuidString.lowercased()
            let relativePath = "users/\(userSlug)/\(setupID)/view-\(submissionID).ipynb"
            let payload = try await ensureUserNotebookWorkingCopy(
                req: req,
                setupID: setupID,
                userID: userID,
                fallbackSetup: setup,
                relativePath: relativePath
            )
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
            return Response(status: .ok, headers: headers, body: .init(data: payload))
        }

        let fileKind = notebookFileKind(from: query.file)
        let assignment = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .first()
        let defaultData: Data? = if fileKind == .solution {
            try await solutionNotebookData(for: assignment, setup: setup, db: req.db)
        } else {
            nil
        }

        let payload = try await ensureUserNotebookWorkingCopy(
            req: req,
            setupID: setupID,
            userID: userID,
            fallbackSetup: setup,
            relativePath: userNotebookWorkingCopyRelativePath(setupID: setupID, userID: userID, fileKind: fileKind),
            defaultData: defaultData
        )

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(data: payload))
    }
}

// MARK: - Notebook helpers

func userNotebookWorkingCopyRelativePath(setupID: String, userID: UUID) -> String {
    userNotebookWorkingCopyRelativePath(setupID: setupID, userID: userID, fileKind: .assignment)
}

private func notebookFileKind(from rawValue: String?) -> NotebookFileKind {
    NotebookFileKind(rawValue: (rawValue ?? "").lowercased()) ?? .assignment
}

private func userNotebookFilename(fileKind: NotebookFileKind) -> String {
    switch fileKind {
    case .assignment: return "assignment.ipynb"
    case .solution: return "solution.ipynb"
    }
}

func userNotebookWorkingCopyRelativePath(
    setupID: String,
    userID: UUID,
    fileKind: NotebookFileKind
) -> String {
    "users/\(userID.uuidString.lowercased())/\(setupID)/\(userNotebookFilename(fileKind: fileKind))"
}

func userNotebookWorkingCopyAbsolutePath(req: Request, setupID: String, userID: UUID) -> String {
    req.application.directory.publicDirectory
        + "jupyterlite/files/"
        + userNotebookWorkingCopyRelativePath(setupID: setupID, userID: userID)
}

func ensureUserNotebookWorkingCopy(
    req: Request,
    setupID: String,
    userID: UUID,
    fallbackSetup: APITestSetup,
    relativePath: String? = nil,
    defaultData: Data? = nil,
    overwriteWith: Data? = nil
) async throws -> Data {
    let fileManager = FileManager.default
    let resolvedRelativePath = relativePath ?? userNotebookWorkingCopyRelativePath(setupID: setupID, userID: userID)
    let workingCopyPath = req.application.directory.publicDirectory
        + "jupyterlite/files/"
        + resolvedRelativePath
    let workingCopyDir = (workingCopyPath as NSString).deletingLastPathComponent

    if let overwriteWith {
        try fileManager.createDirectory(atPath: workingCopyDir, withIntermediateDirectories: true)
        try overwriteWith.write(to: URL(fileURLWithPath: workingCopyPath))
        createSupportFileSymlinks(req: req, setup: fallbackSetup, studentDir: workingCopyDir)
        removeLegacyUserNotebookCopies(req: req, userID: userID)
        return overwriteWith
    }

    if let existingData = try? Data(contentsOf: URL(fileURLWithPath: workingCopyPath)),
       !existingData.isEmpty,
       (try? JSONSerialization.jsonObject(with: existingData)) != nil {
        // Symlinks are idempotent — run on every visit so existing working copies
        // also pick up support files when the feature is first deployed.
        createSupportFileSymlinks(req: req, setup: fallbackSetup, studentDir: workingCopyDir)
        removeLegacyUserNotebookCopies(req: req, userID: userID)
        return existingData
    }

    let seedData = if let defaultData {
        defaultData
    } else {
        try await latestNotebookSubmissionData(
            req: req,
            setupID: setupID,
            userID: userID,
            fallbackSetup: fallbackSetup
        ).data
    }

    try fileManager.createDirectory(atPath: workingCopyDir, withIntermediateDirectories: true)
    try seedData.write(to: URL(fileURLWithPath: workingCopyPath))
    createSupportFileSymlinks(req: req, setup: fallbackSetup, studentDir: workingCopyDir)

    removeLegacyUserNotebookCopies(req: req, userID: userID)
    return seedData
}

private func solutionNotebookData(
    for assignment: APIAssignment?,
    setup: APITestSetup,
    db: Database
) async throws -> Data {
    if let entryName = listZipEntries(zipPath: setup.zipPath).first(where: { $0.hasPrefix("solution.") }),
       let data = extractZipEntry(zipPath: setup.zipPath, entryName: entryName),
       !data.isEmpty {
        return normalizeNotebookForJupyterLite(data)
    }

    if let validationID = assignment?.validationSubmissionID,
       let validationSubmission = try await APISubmission.find(validationID, on: db),
       let data = try? Data(contentsOf: URL(fileURLWithPath: validationSubmission.zipPath)),
       !data.isEmpty {
        return normalizeNotebookForJupyterLite(data)
    }

    if let setupID = assignment?.testSetupID,
       let fallbackSubmission = try await APISubmission.query(on: db)
        .filter(\.$testSetupID == setupID)
        .filter(\.$kind == APISubmission.Kind.validation)
        .sort(\.$submittedAt, .descending)
        .first(),
       let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackSubmission.zipPath)),
       !data.isEmpty {
        return normalizeNotebookForJupyterLite(data)
    }

    throw Abort(.notFound, reason: "No solution notebook is available for this assignment yet")
}

func notebookDataForHistorySelection(
    req: Request,
    caller: APIUser,
    submissionID: String,
    setupID: String,
    userID: UUID
) async throws -> Data {
    guard let submission = try await APISubmission.find(submissionID, on: req.db) else {
        throw Abort(.notFound, reason: "Submission not found")
    }
    guard submission.kind == APISubmission.Kind.student else {
        throw Abort(.forbidden)
    }
    if !caller.isInstructor && submission.userID != userID {
        throw Abort(.forbidden)
    }
    guard submission.testSetupID == setupID else {
        throw Abort(.badRequest, reason: "Submission does not belong to this assignment")
    }

    let pathExt = URL(fileURLWithPath: submission.zipPath).pathExtension.lowercased()
    let nameExt = (submission.filename ?? "").lowercased()
    guard pathExt == "ipynb" || nameExt.hasSuffix(".ipynb") else {
        throw Abort(.badRequest, reason: "Only notebook submissions can be opened in notebook view")
    }

    let dataURL = URL(fileURLWithPath: submission.zipPath)
    guard let data = try? Data(contentsOf: dataURL),
          (try? JSONSerialization.jsonObject(with: data)) != nil else {
        throw Abort(.notFound, reason: "Notebook artifact is unavailable for this submission")
    }
    return normalizeNotebookForJupyterLite(data)
}

func removeLegacyUserNotebookCopies(req: Request, userID: UUID) {
    let userSlug = userID.uuidString.lowercased()
    let roots = [
        req.application.directory.publicDirectory + "files/",
        req.application.directory.publicDirectory + "jupyterlite/files/",
        req.application.directory.publicDirectory + "jupyterlite/lab/files/",
        req.application.directory.publicDirectory + "jupyterlite/notebooks/files/"
    ]

    let fileManager = FileManager.default
    for root in roots {
        let userDir = root + "users/\(userSlug)/"
        guard let entries = try? fileManager.contentsOfDirectory(atPath: userDir) else { continue }

        for name in entries {
            let path = userDir + name
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            guard URL(fileURLWithPath: name).pathExtension.lowercased() == "ipynb" else {
                continue
            }
            let lower = name.lowercased()
            let shouldRemove = lower == "assignment.ipynb"
                || lower == "submission.ipynb"
                || (lower.hasPrefix("sub_") && lower.hasSuffix(".ipynb"))
            guard shouldRemove else { continue }
            try? fileManager.removeItem(atPath: path)
        }
    }
}

func latestNotebookSubmissionData(
    req: Request,
    setupID: String,
    userID: UUID,
    fallbackSetup: APITestSetup
) async throws -> (data: Data, filename: String?) {
    let submissions = try await APISubmission.query(on: req.db)
        .filter(\.$testSetupID == setupID)
        .filter(\.$userID == userID)
        .filter(\.$kind == APISubmission.Kind.student)
        .sort(\.$submittedAt, .descending)
        .all()

    for submission in submissions {
        let pathExt = URL(fileURLWithPath: submission.zipPath).pathExtension.lowercased()
        let nameExt = (submission.filename ?? "").lowercased()
        guard pathExt == "ipynb" || nameExt.hasSuffix(".ipynb") else {
            continue
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: submission.zipPath)),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            continue
        }
        return (data, submission.filename)
    }

    let fallbackFilename: String? = {
        guard let path = fallbackSetup.notebookPath, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }()
    let fallbackData = try notebookData(for: fallbackSetup)
    return (fallbackData, fallbackFilename)
}

/// Creates read-only symlinks for support files (zip entries that are not test suite
/// scripts or canonical notebooks) inside the student's JupyterLite working directory.
///
/// Symlinks point to the shared extraction in `{testSetupsDir}/shared/{setupID}/`
/// that is populated by `extractSupportFilesToSharedDirectory` when the test setup
/// is created or edited. Only files that exist in the shared directory are linked;
/// missing files are silently skipped so a missing shared dir never breaks notebook access.
func createSupportFileSymlinks(req: Request, setup: APITestSetup, studentDir: String) {
    guard let setupID = setup.id else { return }

    // Derive the list of support files: everything in the zip except test suite scripts
    // and the canonical notebooks.
    guard let manifestData = setup.manifest.data(using: .utf8),
          let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: manifestData)
    else { return }

    let testScriptNames = Set(props.testSuites.map { $0.script })
    let reservedNames: Set<String> = ["assignment.ipynb", "solution.ipynb"]
    let allEntries = listZipEntries(zipPath: setup.zipPath)
    let supportNames = allEntries.filter {
        !testScriptNames.contains($0) && !reservedNames.contains($0)
    }
    guard !supportNames.isEmpty else { return }

    let sharedDir = req.application.testSetupsDirectory + "shared/\(setupID)/"
    let fm = FileManager.default

    for name in supportNames {
        let src  = sharedDir + name
        let dest = studentDir + "/" + name
        guard !fm.fileExists(atPath: dest) else { continue }   // idempotent
        guard  fm.fileExists(atPath: src)  else { continue }   // skip if not yet extracted
        try? fm.createSymbolicLink(atPath: dest, withDestinationPath: src)
    }
}
