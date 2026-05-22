// APIServer/Routes/Web/PublishedAssignmentRoutes.swift
//
// Instructor-facing routes for editing a *published* assignment: file
// downloads (notebook, solution, support items), inline save, script CRUD
// inside the setup zip, the unified suite editor (and its section CRUD),
// pattern-family + notebook-check editors, and assignment-scope global
// variables.  Also hosts the two `/instructor`-scope utilities used by
// both the new-assignment and edit-assignment pages — `script-templates`
// (static template registry) and `scan-notebook` (function-shape probe).
//
// Extracted from `AssignmentRoutes` in v0.4.177 — Phase 2 of the
// audit-driven refactor.  No behaviour change.  The handlers themselves
// live in:
//   - `AssignmentRoutes+Editor.swift`
//   - `AssignmentRoutes+Suite.swift`
//   - `AssignmentRoutes+SuiteSections.swift`
//   - `AssignmentRoutes+GlobalVariables.swift`
//   - `AssignmentRoutes+Families.swift`
//   - `AssignmentRoutes+Checks.swift`
// each now extending this struct.

import Core
import Fluent
import Foundation
import Vapor

struct PublishedAssignmentRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let r = routes.grouped("instructor")

        // Save + file downloads.
        r.post(":assignmentID", "edit", "save", use: saveEditedAssignment)
        r.get(":assignmentID", "files", "notebook", use: downloadCurrentNotebookFile)
        r.get(":assignmentID", "files", "solution", use: downloadCurrentSolutionFile)
        r.get(":assignmentID", "files", "item", use: downloadCurrentSetupItem)
        r.post(":assignmentID", "create-solution", use: createSolutionFromAssignment)

        // Shared /instructor-scope utilities (used by both new + edit pages).
        r.get("script-templates", use: getScriptTemplates)
        r.post("scan-notebook", use: scanNotebook)

        // Script editor — inline CRUD for individual test/support files in the setup zip.
        r.get(":assignmentID", "scripts", ":filename", use: getScript)
        r.put(":assignmentID", "scripts", ":filename", use: updateScript)
        r.post(":assignmentID", "scripts", use: createScript)
        r.delete(":assignmentID", "scripts", ":filename", use: deleteScript)

        // Unified suite editor — GET returns the full reconciled test-item
        // list (scripts + families + checks, in manifest order, raw-script
        // bodies inlined).  PUT replaces the whole list atomically; every
        // mutation in the suite-edit UI (reorder, tier/points, family + check
        // create/edit/delete) sends a fresh snapshot here and replaces its
        // local state from the response.  This is the single write surface
        // for pattern families and notebook checks: the dedicated
        // PUT /families and PUT /checks endpoints were retired in v0.4.227
        // (their saves were folded into PUT /suite in v0.4.226).
        r.get(":assignmentID", "suite", use: getSuite)
        r.put(":assignmentID", "suite", use: putSuite)

        // Suite-section CRUD — per-op, form-POST + redirect.
        r.post(":assignmentID", "suite-sections", use: createSuiteSection)
        r.post(":assignmentID", "suite-sections", "reorder", use: reorderSuiteSections)
        r.post(":assignmentID", "suite-sections", ":sectionID", "rename", use: renameSuiteSection)
        r.post(":assignmentID", "suite-sections", ":sectionID", "delete", use: deleteSuiteSection)
        r.post(":assignmentID", "suite-sections", ":sectionID", "variables", use: updateSuiteSectionVariables)

        // Assignment-scope global variables.
        r.get(":assignmentID", "global-variables", use: getGlobalVariables)
        r.put(":assignmentID", "global-variables", use: putGlobalVariables)
    }
}
