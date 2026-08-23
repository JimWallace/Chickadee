// APIServer/Routes/Web/InstructorWorkbenchRoutes.swift
//
//   GET /instructor/:assignmentID/workbench  → workbench.leaf (one document)
//
// The assignment workbench puts the instructor edit page and the notebook
// editor side by side, so an author can read and change variables, suite
// entries and deadlines while a Pyodide kernel boots or a validation run
// finishes.  Before it, every hop between the two cost a full editor cold
// boot, and switching from the starter notebook to the reference solution
// cost a third.
//
// **#1266: this is now a single document.**  It renders both halves inline:
//
//   left  → #extend("_assignment-edit-body", edit)
//   right → #extend("_notebook-body", notebook)
//
// Each partial is the *same file* the corresponding standalone page extends,
// bound against a sub-context, so there is one copy of each body's markup and
// the panes cannot drift from the pages they mirror.
//
// It used to compose the two as same-origin iframes.  Both reasons that
// design gave for composing-not-merging are gone:
//
//   1. "A merged Leaf template is not available to us" — LeafKit 1.14.2 was
//      said to fail with `extend only supports one or two parameters` on a
//      second inline `#extend`.  On 1.14.3 it does not; a spike added a probe
//      partial, asserted it rendered, and confirmed the assertion goes red
//      when the extend is removed.
//   2. "`notebook.js` is a single-instance IIFE bound to `#jl-frame`" — still
//      true, and still respected: the merged page has exactly **one**
//      `#jl-frame`.  Only the two *wrapper* iframes went away.
//
// See `InstructorWorkbenchRoutes+COEP` note in `COEPMiddleware`: this route
// must be cross-origin isolated, or the editor iframe silently loses
// `SharedArrayBuffer` and the kernel drops onto the service-worker transport
// the codebase deliberately moved off.  The merge removes a link in the
// ancestor chain rather than adding one, but the requirement is unchanged and
// `workbench-check.mjs` re-proves it.

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
    }

    // MARK: - GET /instructor/:assignmentID/workbench

    @Sendable
    func workbenchPage(req: Request) async throws -> View {
        let (assignment, setup) = try await loadAssignmentAndSetupForStaffRead(req)
        let setupID = assignment.testSetupID

        // Whether there is a solution to offer a tab for.  Resolved by the
        // shared four-source helper the edit page's Files table and the
        // solution-visibility enable guard also use, so the workbench can
        // never advertise a solution tab the edit page says does not exist,
        // or vice versa.
        let hasSolution = try await assignmentHasSolution(
            assignment: assignment, db: req.db,
            testSetupsDirectory: req.application.testSetupsDirectory)

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
            "assignment:personalized": notebookPaneURL(
                assignmentID: assignment.publicID, file: "assignment", view: "personalized")
        ]
        if assignmentHasTemplate {
            urls["assignment:template"] = notebookPaneURL(
                assignmentID: assignment.publicID, file: "assignment", view: "template")
        }
        if hasSolution {
            urls["solution:personalized"] = notebookPaneURL(
                assignmentID: assignment.publicID, file: "solution", view: "personalized")
            if solutionHasTemplate {
                urls["solution:template"] = notebookPaneURL(
                    assignmentID: assignment.publicID, file: "solution", view: "template")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let urlsJSON = String(data: (try? encoder.encode(urls)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"

        // Which notebook this render puts in the right-hand pane.  Was the
        // iframe's `src`; now it is part of *this* page's identity, so it
        // rides the workbench URL and switching notebooks is an ordinary
        // navigation (see the `wb-view` / Files-table handlers in workbench.js).
        let query = try req.query.decode(WorkbenchQuery.self)
        let fileKind = NotebookFileKind(rawValue: query.file ?? "") ?? .assignment
        // A solution tab that does not exist must not be reachable by URL —
        // `workbenchNotebookContext` would fall back to the starter's bytes
        // under a "Solution" label, which reads as data loss.
        guard fileKind == .assignment || hasSolution else {
            throw Abort(.notFound, reason: "This assignment has no reference solution.")
        }

        let user = try req.auth.require(APIUser.self)
        // A missing notebook degrades the right pane rather than failing the
        // page — see `AssignmentWorkbenchContext.notebook`.  Scoped to
        // `NotebookLookupError`: a permission or database failure is still an error,
        // not an empty pane.
        var notebookCtx: NotebookContext?
        do {
            notebookCtx = try await WebRoutes().workbenchNotebookContext(
                req: req,
                user: user,
                setup: setup,
                assignment: assignment,
                fileKind: fileKind,
                requestedView: query.view
            )
        } catch let error as NotebookLookupError {
            req.logger.info(
                "workbench_notebook_unavailable assignment=\(assignment.publicID) file=\(fileKind.rawValue) reason=\(error.reason)"
            )
            notebookCtx = nil
        }
        let editCtx = try await InstructorDashboardRoutes().makeEditAssignmentContext(
            req: req, embedded: true)

        let title = assignment.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let ctx = AssignmentWorkbenchContext(
            currentUser: req.currentUserContext,
            assignmentID: assignment.publicID,
            testSetupID: setupID,
            assignmentTitle: title.isEmpty ? "Assignment" : title,
            edit: editCtx,
            notebook: notebookCtx,
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

    /// Which notebook the merged page is showing.  Both are optional and both
    /// are re-resolved server-side, so a forged value cannot widen access:
    /// `file=solution` is rejected above when there is no solution, and
    /// `view=` goes through `resolveNotebookViewMode`, which only hands the
    /// template to staff on a notebook that actually carries placeholders.
    private struct WorkbenchQuery: Content {
        var file: String?
        var view: String?
    }

    /// URL of one (file, view) combination — now a *workbench* URL rather than
    /// a bare notebook URL.
    ///
    /// Before the merge these addressed the notebook page directly, because
    /// they were iframe `src`s. In one document there is no inner frame to
    /// repoint: switching either axis reboots the kernel regardless, so it is
    /// an ordinary navigation to this same route with different arguments, and
    /// the whole page — edit half included — comes back consistent with it.
    ///
    /// `view=` is always sent explicitly.  `resolveNotebookViewMode` defaults
    /// staff to `.template` on a notebook that carries placeholders, so leaving
    /// it off would silently make the page's identity depend on the
    /// assignment's content — "Assignment" would mean the template on a
    /// personalized lab and the rendering on every other one.
    private func notebookPaneURL(assignmentID: String, file: String, view: String) -> String {
        "/instructor/\(assignmentID)/workbench?file=\(file)&view=\(view)"
    }
}
