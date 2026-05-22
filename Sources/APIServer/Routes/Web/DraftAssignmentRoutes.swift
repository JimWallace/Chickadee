// APIServer/Routes/Web/DraftAssignmentRoutes.swift
//
// Instructor-facing routes for the draft-assignment authoring flow:
// the New Assignment page, draft-scoped suite / family / check / script
// editing, draft suite-section CRUD, save, and the final `publish` step
// that transitions a draft into a published assignment.
//
// Extracted from `AssignmentRoutes` in v0.4.177 — Phase 2 of the
// audit-driven refactor.  No behaviour change.  The handlers themselves
// live in:
//   - `AssignmentRoutes+NewAssignment.swift`
//   - `AssignmentRoutes+NewPage.swift`
//   - `AssignmentRoutes+SaveValidation.swift`
//   - `AssignmentRoutes+Draft.swift`
//   - `AssignmentRoutes+DraftSections.swift`
// each now extending this struct.

import Core
import Fluent
import Foundation
import Vapor

struct DraftAssignmentRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let r = routes.grouped("instructor")
        r.get("new", use: newAssignmentPage)
        r.post("new", "draft", use: updateNewAssignmentDraft)
        r.get("new", "draft", "solution-notebook", use: draftSolutionNotebook)
        // Draft-scoped suite / scripts endpoints.  Mirror the
        // `:assignmentID`-scoped routes on `PublishedAssignmentRoutes`,
        // but identify the target `APITestSetup` via a `draftID` query
        // parameter because the assignment hasn't been published yet.
        // Pattern families + notebook checks are written through PUT /suite
        // (the dedicated draft /families and /checks endpoints were retired
        // in v0.4.227, mirroring the published side).
        r.get("new", "draft", "suite", use: getDraftSuite)
        r.put("new", "draft", "suite", use: putDraftSuite)
        r.post("new", "draft", "scripts", use: createDraftScript)
        r.delete("new", "draft", "scripts", ":filename", use: deleteDraftScript)
        r.get("new", "draft", "files", "item", use: downloadDraftSetupItem)
        // Draft-scoped suite-section CRUD (mirrors the published routes).
        r.post("new", "draft", "suite-sections", use: createDraftSuiteSection)
        r.post("new", "draft", "suite-sections", "reorder", use: reorderDraftSuiteSections)
        r.post("new", "draft", "suite-sections", ":sectionID", "rename", use: renameDraftSuiteSection)
        r.post("new", "draft", "suite-sections", ":sectionID", "delete", use: deleteDraftSuiteSection)
        r.post("new", "draft", "suite-sections", ":sectionID", "variables", use: updateDraftSuiteSectionVariables)
        // Save + publish.
        r.post("new", "save", use: saveNewAssignment)
        r.post(use: publish)
    }
}
