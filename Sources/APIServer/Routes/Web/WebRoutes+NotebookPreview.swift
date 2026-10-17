// APIServer/Routes/Web/WebRoutes+NotebookPreview.swift
//
// Preview as student (notebook views NB6b): the workbench shows the
// assignment notebook as one student gets it, personalized with that
// student's seed, read-only, with the task headers in the "not submitted"
// state.
//
// The preview is the staff member's own file. It never touches the student's
// working copy, submissions or participation. The one write on the student's
// behalf is their seed: `AssignmentSeedStore.ensureSeed` creates it when the
// student has none yet, and it is then the seed they get when they open the
// lab, so the preview shows their real values.

import Core
import Fluent
import Foundation
import SystemPackage
import Vapor

extension WebRoutes {

    /// The notebook context for a workbench preview of `student`'s notebook.
    /// The caller has checked that the viewer is course staff and that
    /// `student` is enrolled as a student in the course.
    func workbenchPreviewContext(
        req: Request,
        user: APIUser,
        setup: APITestSetup,
        assignment: APIAssignment,
        student: WorkbenchPreviewStudent
    ) async throws -> NotebookContext {
        guard let viewerID = user.id, let setupID = setup.id else { throw Abort(.unauthorized) }
        guard
            let data = await personalizedStarterNotebook(
                setup: setup, userID: student.userID, on: req.db, application: req.application,
                logger: req.logger)
        else { throw NotebookLookupError.notFound(setupID: setupID) }

        // In the viewer's own directory, under a name of its own, so it never
        // collides with their working copy of the starter.
        let relativePath =
            "users/\(viewerID.uuidString.lowercased())/\(setupID)/preview-\(student.token).ipynb"
        let absolutePath = req.application.directory.publicDirectory + "jupyterlite/files/" + relativePath
        try await runBlocking {
            try FileManager.default.createDirectory(
                atPath: FilePath(absolutePath).removingLastComponent().string, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: absolutePath))
        }

        let encodedPath = relativePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? relativePath
        // A workspace of its own: JupyterLite keeps a layout and an IndexedDB
        // copy per workspace, and a preview must not show the viewer's edits.
        let workspaceID = "\(setupID)-\(viewerID.uuidString.lowercased())-preview-\(student.token)"
        let title = assignment.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return NotebookContext(
            testSetupID: setupID,
            assignmentTitle: title.isEmpty ? "Assignment" : title,
            notebookURL: "/jupyterlite/files/" + encodedPath,
            jupyterLiteEditorURL:
                "/jupyterlite/notebooks/index.html?workspace=\(workspaceID)&reset=&path=\(encodedPath)",
            downloadURL: nil,
            gradingMode: decodeManifestGradingMode(setup),
            browserUnsupported: SupportedBrowserMatrix.assess(req).tier == .unsupported,
            showSubmit: false,
            isClosed: false,
            isReadOnly: true,
            canSaveToAssignment: false,
            fileKind: NotebookFileKind.assignment.rawValue,
            isTemplateView: false,
            viewToggleURL: nil,
            solutionViewURL: nil,
            isStudentSolutionView: false,
            workingCopyMtime: workingCopyMtimeEpoch(absolutePath: absolutePath),
            currentUser: req.currentUserContext,
            embedded: true,
            aiFeedbackNotice: false,
            kernelLanguage: NotebookBootFacts.kernelLanguage(manifestJSON: setup.manifest),
            bootBird: NotebookBootFacts.bird(avatarSpecJSON: user.avatarSpecJSON, isStaff: true),
            dueLabel: assignment.dueAt.map { waterlooDateTimeFormatter().string(from: $0) },
            definitionPatterns: NotebookBootFacts.definitionPatterns(manifestJSON: setup.manifest),
            previewGuideURL: "/instructor/\(assignment.publicID)/preview-guide.json?as=\(student.token)"
        )
    }

    /// `student`'s guide with no attempt: what the editor shows them before
    /// their first submission.
    func previewGuide(
        req: Request, setup: APITestSetup, student: WorkbenchPreviewStudent
    ) async throws
        -> NotebookGuide
    {
        guard let manifest = setup.decodedManifest(), let setupID = setup.id else { throw Abort(.notFound) }
        // The student's own key for a guide with no attempt, on purpose: both
        // build from the same inputs (`guideInputs`, `attempt: nil`). If the
        // student's route ever reads anything more, this key must change too.
        let key = NotebookGuideCache.Key(
            userID: student.userID, setupID: setupID, submissionID: nil, graded: false,
            manifestDigest: sha256HexDigest(setup.manifest))
        return try await req.application.notebookGuideCache.guide(for: key) {
            let inputs = try await self.guideInputs(
                req: req, setup: setup, manifest: manifest, userID: student.userID)
            return NotebookGuideBuilder(
                manifest: manifest, solution: inputs.solution, starter: inputs.starter,
                scriptSources: inputs.scripts, attempt: nil
            ).build()
        }
    }
}
