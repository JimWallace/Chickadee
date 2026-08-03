// APIServer/Routes/Web/WebRoutes+NotebookSave.swift
//
// POST /testsetups/:testSetupID/notebook/save?file=assignment|solution
//
// Persists what course staff are editing in the embedded JupyterLite editor
// back to the assignment.  Before this, the editor was a scratchpad: JupyterLite
// keeps its live document in the browser's IndexedDB, the on-disk working copy
// under `jupyterlite/files/users/…` was only ever *seeded* by the server, and
// the only ways to change an assignment's notebooks were an upload on the
// new-assignment page or the MCP `update_notebook` / `update_solution` tools.
//
// This is the web sibling of those two tools and deliberately reuses their
// server-side steps, so the browser and the agent can't drift:
//
//   - starter notebook → `AssignmentAuthoringService.writeAssignmentNotebook`
//     (the same normalization + flat-file write the editor Save path uses),
//     then the debounced `scheduleValidationAfterSuiteEdit`.
//   - reference solution → a fresh `kind == .validation` submission via
//     `enqueueRunnerValidationSubmission`, linked as the assignment's
//     validation submission — the same storage the "Save & Validate" button
//     and `update_solution` use, because that submission *is* where an
//     assignment's solution lives.
//
// Two deliberate differences from the MCP tools:
//
//   - **Visibility is never changed.** The MCP write tools close an open
//     assignment; the web live-edit endpoints (`PUT /suite`, `PUT /families`)
//     deliberately do not, because pulling an assignment out from under a lab
//     in progress is worse than the risk being guarded against — neither
//     notebook changes what the suite grades.  This is a live-edit endpoint, so
//     it follows the live-edit rule.  The `Save & Validate` button on the edit
//     page still closes, as it always has.
//   - **The author's working copy is written too**, so a reload of the editor
//     (which reseeds from disk when the server's copy is newer) shows what was
//     saved, and so the new-assignment draft flow — which reads the working
//     copy via `draftNotebookData` — sees the edit on a setup that has no
//     assignment row yet.

import Core
import Fluent
import Foundation
import Vapor

extension WebRoutes {

    /// JSON result of a notebook save, rendered by `notebook.js` in the page's
    /// status line.
    struct NotebookSaveResult: Content {
        let saved: Bool
        let fileKind: String
        let cellCount: Int
        let validationStatus: String?
        let message: String
    }

    // MARK: - POST /testsetups/:testSetupID/notebook/save

    @Sendable
    func saveNotebookFromEditor(req: Request) async throws -> NotebookSaveResult {
        struct SaveQuery: Content {
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

        // The same gate every other authoring write goes through: TA+ in this
        // setup's *own* course (admin bypass), archived courses refused.
        // Notebook/solution edits are `.ta` content work — see the role-floor
        // convention on `evaluateCourseWrite`.
        try await requireCourseWriteAccess(
            caller: user, courseID: setup.courseID, atLeast: .ta, db: req.db)

        let fileKind = notebookFileKind(from: (try? req.query.decode(SaveQuery.self))?.file)

        guard let buffer = req.body.data, buffer.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "The request body must be the notebook JSON.")
        }
        let raw = Data(buffer.readableBytesView)
        guard let cellCount = notebookCellCount(fromRaw: raw) else {
            throw Abort(
                .badRequest,
                reason: "That does not look like a notebook — expected .ipynb JSON with a \"cells\" array.")
        }
        let asEdited = normalizeNotebookForJupyterLite(raw)

        let assignment = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .first()

        // The copy in the author's editor is a *rendering*: the server
        // substituted their own values into every `{{name}}` placeholder before
        // handing it over. Storing that verbatim would replace the class's
        // template with one person's data, so the personalized cells are
        // restored from the notebook currently stored before anything is
        // written. A no-op on an assignment without personalization.
        let canonical = try await canonicalNotebookData(
            req: req, setup: setup, assignment: assignment, fileKind: fileKind)
        let toStore: Data
        switch PersonalizedCellRestoration.restoreTemplates(in: asEdited, canonical: canonical) {
        case .restored(let restored):
            toStore = restored
        case .unmatched(let placeholders):
            throw Abort(
                .conflict,
                reason: """
                    This copy has per-student values substituted into it, and the \
                    original \(placeholders.map { "{{\($0)}}" }.joined(separator: ", ")) \
                    placeholder cells could not be matched to the stored notebook — \
                    saving would replace them with one student's values. Reset this \
                    notebook to the current starter, redo the edit without moving the \
                    personalized cells, and save again.
                    """)
        }

        // Content-versioning seam: seeds the pre-edit baseline and registers the
        // setup so `AssignmentVersionCaptureMiddleware` snapshots this save.
        // The parameterized write helpers do this from
        // `loadAssignmentAndSetupForWrite`; this handler reaches its setup by
        // id, so it registers by hand (as `update_solution` does over MCP).
        await req.beginAssignmentContentEdit(setup: setup)

        // The author's working copy keeps the *rendered* bytes they were
        // editing — the same personalized view they had a second ago, and the
        // one that actually runs — while the assignment stores the template.
        _ = try await ensureUserNotebookWorkingCopy(
            req: req,
            setupID: setupID,
            userID: userID,
            fallbackSetup: setup,
            relativePath: userNotebookWorkingCopyRelativePath(
                setupID: setupID, userID: userID, fileKind: fileKind),
            overwriteWith: asEdited
        )

        let outcome =
            switch fileKind {
            case .assignment:
                try await persistStarterNotebook(
                    req: req, setup: setup, assignment: assignment, normalized: toStore)
            case .solution:
                try await persistSolutionNotebook(
                    req: req, setup: setup, assignment: assignment, normalized: toStore,
                    submitterUserID: userID)
            }

        let validationLabel = outcome.validationStatus ?? "none"
        req.logger.info(
            "notebook_editor_save setup=\(setupID) file=\(fileKind.rawValue) cells=\(cellCount) author=\(userID.uuidString) validation=\(validationLabel)"
        )

        return NotebookSaveResult(
            saved: true,
            fileKind: fileKind.rawValue,
            cellCount: cellCount,
            validationStatus: outcome.validationStatus,
            message: outcome.message
        )
    }

    /// The notebook currently stored for `fileKind` — the one still carrying
    /// `{{name}}` templates — or nil when there is nothing stored yet (a draft
    /// whose solution has never been saved). Same resolution the notebook page
    /// itself seeds working copies from, so the two always agree on what the
    /// canonical bytes are.
    private func canonicalNotebookData(
        req: Request,
        setup: APITestSetup,
        assignment: APIAssignment?,
        fileKind: NotebookFileKind
    ) async throws -> Data? {
        switch fileKind {
        case .assignment:
            return try? notebookData(for: setup)
        case .solution:
            return try? await solutionNotebookData(for: assignment, setup: setup, db: req.db)
        }
    }

    /// What one save did, in the two fields the page reports.
    private struct NotebookSaveOutcome {
        let validationStatus: String?
        let message: String
    }

    /// Starter-notebook save: rewrite the setup's flat notebook (the bytes every
    /// student's copy is seeded from), then let the debounced validation helper
    /// re-check the suite against the existing solution.
    private func persistStarterNotebook(
        req: Request,
        setup: APITestSetup,
        assignment: APIAssignment?,
        normalized: Data
    ) async throws -> NotebookSaveOutcome {
        do {
            try await AssignmentAuthoringService.writeAssignmentNotebook(
                setup: setup,
                notebookData: normalized,
                setupsDirectory: req.application.testSetupsDirectory,
                on: req.db)
        } catch let error as AssignmentAuthoringError {
            throw Abort(.internalServerError, reason: "Could not write the notebook: \(error)")
        }

        guard let assignment else {
            // A setup with no assignment row is a new-assignment draft; there is
            // nothing to validate until it is published.
            return NotebookSaveOutcome(
                validationStatus: nil, message: "Notebook saved to the draft.")
        }
        // Debounced + best-effort, exactly as after a live suite edit: a no-op
        // when a validation is already pending or no solution exists yet.
        await scheduleValidationAfterSuiteEdit(req: req, assignment: assignment)
        return NotebookSaveOutcome(
            validationStatus: assignment.validationStatus,
            message: validationSuffixed("Starter notebook saved.", status: assignment.validationStatus))
    }

    /// Solution save: an assignment's reference solution *is* its latest
    /// `kind == .validation` submission, so storing one is what persists the
    /// edit — and re-running validation against the new answer key is the point
    /// of saving it.
    private func persistSolutionNotebook(
        req: Request,
        setup: APITestSetup,
        assignment: APIAssignment?,
        normalized: Data,
        submitterUserID: UUID
    ) async throws -> NotebookSaveOutcome {
        guard let assignment else {
            // Draft: the new-assignment page resolves its solution from the
            // draft path (with the working copy, already written above, taking
            // precedence), so write that and stop.
            let draftPath = draftSolutionNotebookPath(
                testSetupsDirectory: req.application.testSetupsDirectory, setupID: setup.id ?? "")
            _ = try ensureDraftNotebookDirectory(
                testSetupsDirectory: req.application.testSetupsDirectory, setupID: setup.id ?? "")
            try normalized.write(to: URL(fileURLWithPath: draftPath))
            return NotebookSaveOutcome(
                validationStatus: nil, message: "Solution saved to the draft.")
        }

        let submissionID = try await enqueueRunnerValidationSubmission(
            req: req,
            setupID: assignment.testSetupID,
            solutionNotebookData: normalized,
            filename: "solution.ipynb",
            submitterUserID: submitterUserID)
        assignment.validationSubmissionID = submissionID

        // Report "no-runner" rather than a `pending` that nothing can claim —
        // the same pre-check `enqueueValidationForEditedAssignment` runs on the
        // Save & Validate path. The submission row is still stored (it is the
        // solution), so it validates on its own once a runner comes up.
        let requirementSpec = try await loadAssignmentRequirementSpec(
            assignment: assignment, on: req.db)
        let hasEligibleRunner = try await ensureCompatibleValidationRunnerAvailability(
            req: req, requirements: requirementSpec)
        assignment.validationStatus = hasEligibleRunner ? "pending" : "no-runner"
        try await assignment.save(on: req.db)

        return NotebookSaveOutcome(
            validationStatus: assignment.validationStatus,
            message: validationSuffixed("Solution saved.", status: assignment.validationStatus))
    }

    /// Appends the one-clause explanation of what validation is doing now, so
    /// the editor's status line answers "and then what?" without a second look
    /// at the dashboard.
    private func validationSuffixed(_ lead: String, status: String?) -> String {
        switch status {
        case "pending":
            return "\(lead) Re-validating against the current test suite."
        case "no-runner":
            return "\(lead) No compatible runner is available, so validation is still queued."
        default:
            return lead
        }
    }
}

/// Number of cells in `raw`, or nil when it is not notebook-shaped JSON (an
/// object carrying a `cells` array).  The web mirror of the MCP tools'
/// `validateNotebookShape` guard: the same rejection, one step earlier, so a
/// stray POST can never overwrite a notebook with something that isn't one.
func notebookCellCount(fromRaw raw: Data) -> Int? {
    guard
        let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
        let cells = object["cells"] as? [Any]
    else {
        return nil
    }
    return cells.count
}
