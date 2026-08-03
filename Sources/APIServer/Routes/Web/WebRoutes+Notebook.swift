// APIServer/Routes/Web/WebRoutes+Notebook.swift
//
// Notebook-related route handlers for WebRoutes (notebook page, raw source,
// student self-service reset).  The filesystem service these handlers call —
// working-copy path planning, participation gate, seeding + substitution,
// history selection, latest-submission fallback, support-file symlinks —
// lives in Services/NotebookWorkingCopyStore.swift.

import Core
import Fluent
import Foundation
import Vapor

enum NotebookFileKind: String {
    case assignment
    case solution
}

extension WebRoutes {

    // MARK: - GET /testsetups/:id/notebook

    @Sendable
    func notebookPage(req: Request) async throws -> Response {
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
        // Staff-ness is per-course (#417 Slice G — was the global
        // `user.isInstructor`). It gates two things here: who may see the
        // reference solution at all, and who keeps an editable editor on a
        // closed assignment.
        let isStaff = try await isCourseStaff(user, inCourse: setup.courseID, db: req.db)
        // The reference solution is staff-only. The student notebook route is
        // reachable by any enrolled student (and now, read-only, for closed
        // assignments), so guard the solution view here rather than relying on
        // the absence of a UI link — never serve the answer key to a student.
        if fileKind == .solution, !isStaff {
            throw Abort(.forbidden, reason: "The solution is only available to course staff.")
        }
        let queryTitle = (query.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let assignment = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .first()
        // Treat an assignment as closed for read-only display whenever it is
        // not effectively open *for this user* — the per-user check honors a
        // deadline extension granted to the current student, so an extended
        // student still sees the Submit button after the assignment-wide
        // deadline.  A bare test setup with no APIAssignment row (instructor
        // preview / unpublished) is treated as not closed so authoring flows
        // are unaffected.
        let isClosed: Bool
        if let assignment {
            // Preview counts as open for staff and closed for students — handled
            // inside isAssignmentEffectivelyOpen — so staff get an editable
            // notebook on a Preview assignment and students see it read-only.
            isClosed = !(try await isAssignmentEffectivelyOpen(assignment, for: user, on: req.db))
        } else {
            isClosed = false
        }

        // Closed-assignment access gate: a closed assignment is only reachable
        // by a student who has previously engaged with it (and that access is
        // recorded durably so it stays reachable once it closes).  Posting
        // links in advance no longer spoils not-yet-opened labs.
        if let redirect = try await closedAssignmentGate(
            req: req, user: user, userID: userID, assignment: assignment, isClosed: isClosed)
        {
            return redirect
        }

        let dbTitle = (assignment?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let assignmentTitle = {
            if !queryTitle.isEmpty { return queryTitle }
            if !dbTitle.isEmpty { return dbTitle }
            return "Assignment"
        }()
        let requestedSubmissionID = (query.submissionID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // --- Submission view (read-only) ---
        // Use a submission-specific working copy path and workspace ID so:
        //   1. The viewer's own assignment working copy is never overwritten.
        //   2. Each submission gets a fresh JupyterLite workspace; the browser
        //      IndexedDB cache from a previous visit to the edit/submit page
        //      cannot shadow the student's actual content.
        let args = NotebookPageRenderArgs(
            user: user,
            setup: setup,
            setupID: setupID,
            userID: userID,
            assignment: assignment,
            assignmentTitle: assignmentTitle,
            isClosed: isClosed,
            isStaff: isStaff
        )
        if !requestedSubmissionID.isEmpty {
            return try await renderSubmissionNotebookView(
                req: req,
                args: args,
                submissionID: requestedSubmissionID
            ).encodeResponse(for: req)
        }

        return try await renderAssignmentNotebookView(
            req: req,
            args: args,
            fileKind: fileKind
        ).encodeResponse(for: req)
    }

    // MARK: - POST /testsetups/:id/reset-notebook
    //
    // Student self-service reset of their *own* working-copy notebook back to
    // the assignment's canonical starter.  Mirrors the instructor-driven
    // `resetStudentNotebook`, but scoped to the caller and gated on the
    // assignment being open to them — `requireOpenStudentAssignment` enforces
    // course enrollment and effective-open state, throwing `.closed` for a
    // closed / not-yet-open assignment and `.notFound` for an unenrolled
    // student.  Past submissions are never touched: only the live working copy
    // at jupyterlite/files/users/{userID}/{setupID}/<filename> is overwritten.
    @Sendable
    func resetOwnNotebook(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.unauthorized) }
        guard
            let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        // A bare test setup with no assignment row is not a student-facing
        // assignment; `requireOpenStudentAssignment` returns nil there without
        // an enrollment check, so reject it explicitly to avoid a bypass.
        guard try await requireOpenStudentAssignment(for: setupID, user: user, on: req) != nil else {
            throw Abort(.notFound)
        }

        let starter: Data
        do {
            starter = try await req.application.notebookBytesCache.notebookData(
                for: NotebookSourceRef(setup))
        } catch {
            throw Abort(.badRequest, reason: "This assignment has no starter notebook to reset to.")
        }

        _ = try await overwriteUserNotebookWithPersonalizedStarter(
            req: req,
            setup: setup,
            setupID: setupID,
            userID: userID,
            starter: starter
        )

        req.logger.info("student_self_notebook_reset setup=\(setupID) student=\(userID.uuidString)")
        return req.redirect(to: "/")
    }

    /// Renders the submission-view branch of `notebookPage` (read-only,
    /// per-submission working copy, fresh JupyterLite workspace).
    private func renderSubmissionNotebookView(
        req: Request,
        args: NotebookPageRenderArgs,
        submissionID requestedSubmissionID: String
    ) async throws -> View {
        let setup = args.setup
        let setupID = args.setupID
        let userID = args.userID
        let userSlug = userID.uuidString.lowercased()
        let notebookData = try await notebookDataForHistorySelection(
            req: req,
            caller: args.user,
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
            overwriteWith: notebookData  // always overwrite — we want the exact submission
        )
        let encodedPath =
            submissionRelativePath
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? submissionRelativePath
        let workspaceID = "\(setupID)-\(userSlug)-view-\(requestedSubmissionID)"
        let editorURL = "/jupyterlite/notebooks/index.html?workspace=\(workspaceID)&reset=1&path=\(encodedPath)"
        let notebookURL = "/testsetups/\(setupID)/notebook/source?submissionID=\(requestedSubmissionID)"
        let submissionViewAbsPath =
            req.application.directory.publicDirectory
            + "jupyterlite/files/" + submissionRelativePath
        return try await req.view.render(
            "notebook",
            NotebookContext(
                testSetupID: setupID,
                assignmentTitle: args.assignmentTitle,
                notebookURL: notebookURL,
                jupyterLiteEditorURL: editorURL,
                downloadURL: nil,  // download link lives on the submission page
                gradingMode: decodeManifestGradingMode(setup),
                browserUnsupported: SupportedBrowserMatrix.assess(req).tier == .unsupported,
                showSubmit: false,  // read-only view
                isClosed: args.isClosed,
                // A past submission is a record, not a working document: it
                // stays locked on exactly the same terms as before the staff
                // authoring bypass below (which is scoped to the assignment /
                // solution notebooks), and it is never savable back to the
                // assignment.
                isReadOnly: args.isClosed,
                canSaveToAssignment: false,
                fileKind: NotebookFileKind.assignment.rawValue,
                workingCopyMtime: workingCopyMtimeEpoch(absolutePath: submissionViewAbsPath),
                currentUser: req.currentUserContext
            ))
    }

    /// Renders the normal assignment / solution branch of `notebookPage`.
    private func renderAssignmentNotebookView(
        req: Request,
        args: NotebookPageRenderArgs,
        fileKind: NotebookFileKind
    ) async throws -> View {
        let setup = args.setup
        let setupID = args.setupID
        let userID = args.userID
        let assignment = args.assignment
        let userSlug = userID.uuidString.lowercased()
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
        let jupyterLiteNotebookPath = userNotebookWorkingCopyRelativePath(
            setupID: setupID, userID: userID, fileKind: fileKind)
        let encodedPath =
            jupyterLiteNotebookPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? jupyterLiteNotebookPath
        let workspaceID = "\(setupID)-\(userSlug)-\(fileKind.rawValue)"
        let editorURL = "/jupyterlite/notebooks/index.html?workspace=\(workspaceID)&reset=&path=\(encodedPath)"
        let notebookURL =
            switch fileKind {
            case .assignment: "/testsetups/\(setupID)/notebook/source"
            case .solution: "/testsetups/\(setupID)/notebook/source?file=solution"
            }
        let downloadURL: String? = {
            guard let assignment else { return nil }
            return switch fileKind {
            case .assignment: "/api/v1/testsetups/\(setupID)/assignment/download"
            case .solution: "/instructor/\(assignment.publicID)/files/solution"
            }
        }()

        let workingCopyAbsPath =
            req.application.directory.publicDirectory
            + "jupyterlite/files/" + jupyterLiteNotebookPath
        // Course staff are the authors of these two notebooks, so the closed
        // state never locks their editor.  Saving an assignment returns it to
        // `.closed` (the close-on-save contract) and a freshly created or
        // cloned assignment starts closed, so the old blanket lock made the
        // starter and solution notebooks uneditable for exactly the window in
        // which they are being written.  Submission stays gated separately —
        // `showSubmit` still follows `isClosed` for everyone.
        let isReadOnly = args.isClosed && !args.isStaff
        // Staff can write the open notebook back to the assignment
        // (`POST /testsetups/:id/notebook/save`).  Mirrors that endpoint's own
        // gate — TA+ on a course that isn't archived — so the button is absent
        // rather than failing when the course is read-only.
        var canSaveToAssignment = false
        if args.isStaff {
            let denial = try await evaluateCourseWrite(
                user: args.user, courseID: setup.courseID, atLeast: .ta, db: req.db)
            canSaveToAssignment = denial == nil
        }
        return try await req.view.render(
            "notebook",
            NotebookContext(
                testSetupID: setupID,
                assignmentTitle: args.assignmentTitle,
                notebookURL: notebookURL,
                jupyterLiteEditorURL: editorURL,
                downloadURL: downloadURL,
                gradingMode: decodeManifestGradingMode(setup),
                browserUnsupported: SupportedBrowserMatrix.assess(req).tier == .unsupported,
                showSubmit: fileKind == .assignment && !args.isClosed,
                isClosed: args.isClosed,
                isReadOnly: isReadOnly,
                canSaveToAssignment: canSaveToAssignment,
                fileKind: fileKind.rawValue,
                workingCopyMtime: workingCopyMtimeEpoch(absolutePath: workingCopyAbsPath),
                currentUser: req.currentUserContext
            ))
    }

    /// Bundles the common state passed to both `notebookPage` render
    /// branches.  Reduces the per-helper parameter count and keeps the
    /// rendering signatures intentionally close to one another.
    private struct NotebookPageRenderArgs {
        let user: APIUser
        let setup: APITestSetup
        let setupID: String
        let userID: UUID
        let assignment: APIAssignment?
        let assignmentTitle: String
        let isClosed: Bool
        /// Whether the viewer is staff (TA+ or admin) of this setup's course.
        /// Staff author content in this editor, so they are never locked out
        /// of the assignment / solution notebook by the closed state.
        let isStaff: Bool
    }

    /// Decodes the manifest's `gradingMode` for the notebook template;
    /// falls back to `.browser` whenever the manifest can't be decoded.
    private func decodeManifestGradingMode(_ setup: APITestSetup) -> String {
        let data = Data(setup.manifest.utf8)
        guard let manifest = decodeManifest(from: data) else {
            return GradingMode.browser.rawValue
        }
        return manifest.gradingMode.rawValue
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

        // Same closed-assignment gate as the notebook page, applied to the raw
        // content endpoint so a student can't fetch a not-yet-opened lab's
        // starter notebook by hitting `/notebook/source` directly.  A
        // legitimately reachable closed assignment already has a participation
        // row (or a submission), so this never fires on normal page loads.
        let isStaff = try await isCourseStaff(user, inCourse: setup.courseID, db: req.db)
        if !isStaff,
            let assignment = try await APIAssignment.query(on: req.db)
                .filter(\.$testSetupID == setupID)
                .first(),
            !(try await isAssignmentEffectivelyOpen(assignment, for: user, on: req.db)),
            !(try await studentHasOpenedAssignment(assignment: assignment, userID: userID, on: req.db))
        {
            throw Abort(.forbidden)
        }

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
        let defaultData: Data? =
            if fileKind == .solution {
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
