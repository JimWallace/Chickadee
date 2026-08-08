// APIServer/Routes/Web/NewAssignmentDraftPayload.swift
//
// Parsed payload for `POST /instructor/new/draft`.  Resolves the
// array-typed (`suiteFiles[]`) and single-typed (`suiteFiles`) Vapor
// decode paths into one shape, and reads each text field through
// `multipartTextField` first (so urlencoded-form clients and
// multipart-form clients see the same final values).  Mirrors the
// `SaveEditedAssignmentForm` / `parseSaveEditedAssignmentForm` pattern
// used by `saveEditedAssignment` in `AssignmentRoutes+Editor.swift`.
//
// Lives at file-internal visibility so `NewAssignmentDraftService`
// (Sources/APIServer/Services/) can construct one without importing
// fileprivate handler internals.  The parser itself
// (`parseNewAssignmentDraftPayload(req:)`) stays inside the route
// file because it's only called from one place.

import Vapor

struct NewAssignmentDraftPayload {
    let assignmentName: String
    let dueAt: String
    let startsAt: String
    let sectionIDRaw: String
    let draftIDRaw: String?
    let action: String
    let assignmentNotebookFile: File?
    let solutionNotebookFile: File?
    let suiteFiles: [File]
    let suiteConfigRaw: String?
    let requiredPlatform: String
    let requiredArchitecture: String
    let requiredLanguagesCSV: String
    let requiredCapabilitiesCSV: String
    /// The Language select's value: an `AssignmentLanguage` raw value, or
    /// `noLanguageChoice` for a plain shell-script suite. Empty when the form
    /// omitted it, which the publish path treats as "not answered" and
    /// refuses rather than guessing.
    let assignmentLanguage: String
}
