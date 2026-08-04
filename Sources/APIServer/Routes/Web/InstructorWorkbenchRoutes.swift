// APIServer/Routes/Web/InstructorWorkbenchRoutes.swift
//
//   GET /instructor/:assignmentID/workbench        → workbench.leaf (the shell)
//   GET /instructor/:assignmentID/workbench/panel  → assignment-edit.leaf (embedded)
//
// The assignment workbench puts the instructor edit page and the notebook
// editor side by side, so an author can read and change variables, suite
// entries and deadlines while a Pyodide kernel boots or a validation run
// finishes.  Before it, every hop between the two cost a full editor cold
// boot, and switching from the starter notebook to the reference solution
// cost a third.
//
// The shell renders no assignment content of its own.  It composes two
// *existing* pages as same-origin iframes:
//
//   left  → /instructor/:assignmentID/workbench/panel   (this file)
//   right → /testsetups/:testSetupID/notebook?file=…&embedded=1
//           (`WebRoutes+Notebook.swift`, unchanged apart from the flag)
//
// Composing rather than merging is deliberate, for two independent reasons:
//
//   1. A merged Leaf template is not available to us.  `assignment-edit.leaf`
//      already carries one inline `#extend`, and LeafKit 1.14.2 fails at render
//      with `extend only supports one or two parameters` as soon as a template
//      that size carries a second one — so the decomposition a merge would need
//      is exactly the shape that is broken.
//   2. `notebook.js` is a single-instance IIFE bound to the element `#jl-frame`,
//      with global state for the freeze watchdog, kernel diagnostics and
//      IndexedDB eviction.  Two notebooks as two *documents* needs no change to
//      it at all; two `#jl-frame`s in one document would need it rewritten.
//
// See `InstructorWorkbenchRoutes+COEP` note in `COEPMiddleware`: both routes
// here must be cross-origin isolated, or the nested editor iframe silently
// loses `SharedArrayBuffer` and the kernel drops onto the service-worker
// transport the codebase deliberately moved off.

import Core
import Fluent
import Foundation
import Vapor

struct InstructorWorkbenchRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // Registered under the same `/instructor` group as the rest of the
        // authoring surface, so `ActiveCourseStaffMiddleware` applies; the
        // per-resource gate is `loadAssignmentAndSetupForStaffRead` inside
        // each handler.
        let r = routes.grouped("instructor")
        r.get(":assignmentID", "workbench", use: workbenchPage)
        r.get(":assignmentID", "workbench", "panel", use: workbenchPanel)
    }

    // MARK: - GET /instructor/:assignmentID/workbench

    @Sendable
    func workbenchPage(req: Request) async throws -> View {
        let (assignment, setup) = try await loadAssignmentAndSetupForStaffRead(req)
        let setupID = assignment.testSetupID

        // Whether there is a solution to offer a tab for.  Resolved exactly the
        // way the edit page's Files table resolves it — same helper, same
        // fallback — so the workbench can never advertise a solution tab the
        // edit page says does not exist, or vice versa.
        let existingSolutionName = try await existingSolutionFilename(req: req, assignment: assignment)
        let draftSolutionPath = draftSolutionNotebookPath(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: setupID)
        let hasDraftSolution = FileManager.default.fileExists(atPath: draftSolutionPath)
        let hasSolution =
            existingSolutionName != nil
            || assignment.validationStatus == "passed"
            || assignment.validationSubmissionID != nil
            || hasDraftSolution

        // Whether each notebook still carries `{{name}}` — i.e. whether its
        // template and its rendering are actually different documents. When
        // they are not, offering a view switch would just be two tabs onto
        // identical bytes, so the control is omitted per file.
        let assignmentHasTemplate = hasPlaceholders(try? notebookData(for: setup))
        // Not folded into an `&&`: the right-hand side of `&&` is a
        // non-async autoclosure, so the await has to stand on its own.
        var solutionHasTemplate = false
        if hasSolution {
            let solutionData = try? await solutionNotebookData(
                for: assignment, setup: setup, db: req.db,
                testSetupsDirectory: req.application.testSetupsDirectory)
            solutionHasTemplate = hasPlaceholders(solutionData)
        }

        // Every (file, view) the tabs can reach.  A `template` entry exists only
        // where the notebook actually carries placeholders — otherwise the two
        // readings are byte-identical and switching between them is a kernel
        // reboot for no change.
        var urls: [String: String] = [
            "assignment:personalized": notebookPaneURL(setupID: setupID, file: "assignment", view: "personalized")
        ]
        if assignmentHasTemplate {
            urls["assignment:template"] = notebookPaneURL(
                setupID: setupID, file: "assignment", view: "template")
        }
        if hasSolution {
            urls["solution:personalized"] = notebookPaneURL(
                setupID: setupID, file: "solution", view: "personalized")
            if solutionHasTemplate {
                urls["solution:template"] = notebookPaneURL(
                    setupID: setupID, file: "solution", view: "template")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let urlsJSON = String(data: (try? encoder.encode(urls)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"

        let title = assignment.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let ctx = AssignmentWorkbenchContext(
            currentUser: req.currentUserContext,
            assignmentID: assignment.publicID,
            testSetupID: setupID,
            assignmentTitle: title.isEmpty ? "Assignment" : title,
            editPanelURL: "/instructor/\(assignment.publicID)/workbench/panel",
            initialNotebookURL: urls["assignment:personalized"] ?? "",
            notebookPaneURLsJSON: urlsJSON,
            hasSolution: hasSolution,
            assignmentHasTemplateView: assignmentHasTemplate,
            solutionHasTemplateView: solutionHasTemplate,
            standaloneEditURL: "/instructor/\(assignment.publicID)/edit"
        )
        return try await req.view.render("workbench", ctx)
    }

    /// True when the notebook still holds `{{name}}` placeholders.  Unreadable
    /// bytes answer `false`: the view switch is an affordance, and a missing
    /// notebook has bigger problems — the same reading `notebookPage` takes.
    private func hasPlaceholders(_ data: Data?) -> Bool {
        guard let data else { return false }
        return !NotebookSubstitution.placeholderNames(in: data).isEmpty
    }

    // MARK: - GET /instructor/:assignmentID/workbench/panel

    /// The workbench's left pane: the ordinary edit page, rendered without the
    /// site chrome.  Deliberately a distinct path rather than `/edit?embedded=1`
    /// — `COEPMiddleware` matches on path components, so this keeps the
    /// isolation rule a one-liner and leaves the public `/edit` page's headers
    /// exactly as they were.
    @Sendable
    func workbenchPanel(req: Request) async throws -> View {
        let ctx = try await InstructorDashboardRoutes().makeEditAssignmentContext(
            req: req, embedded: true)
        return try await req.view.render("assignment-edit", ctx)
    }

    /// URL of one notebook pane.  `embedded=1` drops the site chrome; every
    /// access decision on that page (the staff-only solution guard, the closed
    /// gate, `canSaveToAssignment`) is made without reference to it.
    ///
    /// `view=` is always sent explicitly.  `resolveNotebookViewMode` defaults
    /// staff to `.template` on a notebook that carries placeholders, so leaving
    /// it off would silently make a pane's identity depend on the assignment's
    /// content — the "Assignment" tab would show the template on a personalized
    /// lab and the rendering on every other one.  It is still resolved
    /// server-side, so a student who forges one gets their own rendering.
    private func notebookPaneURL(setupID: String, file: String, view: String) -> String {
        "/testsetups/\(setupID)/notebook?file=\(file)&view=\(view)&embedded=1"
    }
}
