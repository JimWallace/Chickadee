// APIServer/Routes/Web/AssignmentContextTypes.swift
//
// View-context structs used as Leaf template data for assignment-related views.
// Extracted from AssignmentRoutes.swift — no behaviour changes.

import Foundation

// MARK: - View context types

struct AssignmentRow: Encodable {
    let setupID: String
    let assignmentID: String?  // nil if unpublished
    let title: String?  // nil if unpublished
    let isOpen: Bool?  // nil if unpublished
    let dueAt: String?
    let status: String  // "unpublished" | "open" | "closed"
    let sortOrder: Int?
    let validationStatus: String
    let validationSubmissionID: String?
    let suiteCount: Int
    let createdAt: String
    let submittedStudentCount: Int?  // nil if unpublished; unique enrolled students who submitted at least once
    let vanityURL: String?  // e.g. "/CS101/lab-1-intro"; nil if unpublished or no active course
}

/// A course section with its grouped assignment rows, used in instructor and student views.
struct CourseSectionRow: Encodable {
    let sectionID: String  // UUID as string
    let name: String
    let defaultGradingMode: String  // "browser" | "worker"
    let sortOrder: Int
    let rows: [AssignmentRow]  // assignments in this section, sorted
}

struct AssignmentsContext: Encodable {
    let currentUser: CurrentUserContext?
    let metrics: [InstructorDashboardMetric]
    let sections: [CourseSectionRow]  // sections with their assignments
    let ungroupedRows: [AssignmentRow]  // assignments/setups not in any section
    let hasSections: Bool
    let hasUngrouped: Bool
    let enrolledStudents: [EnrolledStudentRow]
    let hasEnrolledStudents: Bool  // explicit flag — Leaf's array.isEmpty is unreliable
    let enrolledStudentCount: Int
    let courseEnrollmentMode: String
    let courseIsArchived: Bool
}

struct InstructorDashboardMetric: Encodable {
    let label: String
    let value: String
}

struct EnrolledStudentRow: Encodable {
    let id: String
    let username: String
    let displayName: String
    let role: String  // "student" | "instructor" | "admin" | "(pending)"
    let lastSeenAtText: String
    let lastSeenAtISO: String?
    let submissionsURL: String
    /// URL to POST to to remove this student from the course.  Differs
    /// for active enrollments vs pending pre-enrollments — the template
    /// just uses this verbatim instead of branching on `isPending`.
    let unenrollURL: String
    /// True when this row represents a `pre_enrollments` row (instructor
    /// bulk-enrolled the username via CSV but the student hasn't logged
    /// in yet).  Template renders these visually muted; pending students
    /// have no submissions or last-seen data.
    let isPending: Bool
}

struct AssignmentSubmissionsContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentID: String
    let assignmentTitle: String
    let metrics: [InstructorDashboardMetric]
    let rows: [AssignmentStudentRow]
}

struct AssignmentStudentRow: Encodable {
    let studentID: String
    /// Student's UUID (as string), used in URLs that target the student by
    /// their stable identifier — e.g. the per-student "reset notebook"
    /// action.  Distinct from `studentID` which is the username for display.
    let studentUUID: String
    let surname: String
    let givenNames: String
    let gradeText: String
    let submissionCount: Int
    let hasLatestSubmission: Bool
    let latestSubmissionID: String
    let latestSubmittedAtText: String
    let latestSubmittedAtEpoch: Int  // Unix timestamp (0 if no submission) for chronological sort
    let additionalSubmissionCount: Int
    let fullHistoryURL: String
    let bestGradePercent: Int?
}

struct ValidateContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentID: String
    let setupID: String
    let title: String
    let suiteCount: Int
    let dueAt: String?
}

struct NewAssignmentContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentName: String
    let dueAt: String
    let sections: [CourseSectionRow]  // available sections for the section picker
    let preselectedSectionID: String  // from ?sectionID= query param
    let draftID: String?
    /// JSON-encoded `draftID` (quoted string or `null`) for embedding in an
    /// inline script via `#rawJSON(...)`.  The pattern-family editor uses
    /// this to skip initialisation before a solution notebook has been
    /// uploaded (no draft exists yet → nothing to scan).
    let draftIDJSON: String
    let assignmentNotebook: NewAssignmentNotebookContext?
    let solutionNotebook: NewAssignmentNotebookContext?
    let suiteRows: [EditableSuiteRow]
    let hasSuiteRows: Bool
    /// Files in the test setup zip that aren't tests (tier == "support") —
    /// data fixtures (CSVs, JSON, etc.) bundled with the assignment.
    /// Rendered as their own group at the top of the page alongside the
    /// starter and solution notebooks (parity with the edit page).  Each
    /// row's `url` points at the draft-scoped download endpoint
    /// (`/instructor/new/draft/files/item?draftID=…&name=…`).
    let supportFileRows: [EditableSuiteRow]
    /// Pattern families persisted in the draft's manifest, rendered as JSON
    /// for the `pattern-families-seed` script tag.  `[]` when the draft has
    /// no families (or no draft exists yet).
    let patternFamiliesJSON: String
    /// Notebook checks persisted in the draft's manifest, rendered as JSON
    /// for the `notebook-checks-seed` script tag (parity PR 2 of #433).
    /// `[]` when the draft has none (or no draft exists yet).  The check
    /// editor module parses this once at page load to seed its in-memory
    /// state; every subsequent save replaces it via `PUT /draft/checks`.
    let notebookChecksJSON: String
    /// Full reconciled `GET /suite` payload embedded as JSON.  Same shape
    /// the edit page emits — `suite-table.js` parses it once at page load
    /// as the initial state of the unified items list, and every subsequent
    /// mutation is a PUT whose response replaces the local copy.  Empty
    /// `{"items":[]}` when no draft exists yet.
    let suiteStateJSON: String
    /// Server-rendered shell rows for the v0.4.96 sectioned suite layout
    /// — one row per named section plus a trailing "Ungrouped" block.
    /// Drives the `#for(sec in suiteSectionRows)` loop in
    /// `assignment-new.leaf` (parity with the edit page).  Always returns
    /// at least the Ungrouped block so the suite editor renders even
    /// before a draft has been created.
    let suiteSectionRows: [SuiteSectionShellRow]
    let requiredPlatform: String
    let requiredArchitecture: String
    let requiredLanguagesCSV: String
    let requiredCapabilitiesCSV: String
    let detectedLanguages: [String]
    let detectedCapabilities: [String]
    let detectedLanguagesCSV: String
    let detectedCapabilitiesCSV: String
    let notice: String?
    let error: String?
}

struct NewAssignmentNotebookContext: Encodable {
    let name: String
    let editURL: String
}

struct EditAssignmentContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentID: String
    let testSetupID: String
    let assignmentName: String
    let dueAt: String
    let currentAssignmentFile: String
    let currentAssignmentURL: String
    let assignmentNotebookEditURL: String
    let currentSolutionFile: String?
    let currentSolutionURL: String?
    let solutionNotebookEditURL: String?
    let existingSuiteRows: [EditableSuiteRow]
    /// Files in the test setup zip that aren't tests (tier == "support").
    /// Surface as their own group at the top of the page alongside the
    /// starter and solution notebooks so instructors can see the data
    /// fixtures bundled with the assignment without scrolling through
    /// the test suite.  Same `EditableSuiteRow` shape as the test rows;
    /// rendered with no tier/points columns.
    let supportFileRows: [EditableSuiteRow]
    /// Pattern-family rows shown alongside raw scripts in the suite table.
    /// Generated `.py` entries they produce are filtered out of
    /// `existingSuiteRows` — the family row represents them collectively.
    let familyRows: [FamilySuiteRow]
    /// Pattern families currently defined on this assignment, rendered as a
    /// JSON array.  The editor JS parses it to seed the in-page family list.
    let patternFamiliesJSON: String
    /// Notebook checks currently defined on this assignment, rendered as a
    /// JSON array.  The editor JS parses it to seed the in-page check list.
    /// Empty `[]` for assignments with no checks (the common case until
    /// instructors start using the new editor).
    let notebookChecksJSON: String
    /// Full reconciled `GET /suite` payload embedded as JSON.  The editor JS
    /// parses it once at page load as the initial state of the unified
    /// items list; every subsequent mutation is a PUT whose response
    /// replaces this state.
    let suiteStateJSON: String
    /// Server-rendered shell rows for the suite-sections view (v0.4.98).
    /// One entry per named section (`isUngrouped = false`) in authored
    /// order, plus one trailing `isUngrouped = true` block if any item
    /// currently has no `sectionID` or there are no sections at all.  The
    /// template uses these to render the `.section-block` + `<tbody
    /// data-section-id>` shells that `suite-table.js` populates.
    let suiteSectionRows: [SuiteSectionShellRow]
    /// Slice 1 — assignment-scope global inputs, rendered as the same
    /// `name + valueJSON` shape section variables use.  The new
    /// "Global Inputs" panel at the top of the edit page iterates this
    /// list to seed its initial rows.  Empty when no globals declared.
    let globalVariableRows: [SuiteSectionVariableShellRow]
    let brightspaceSyncEnabled: Bool
    let brightspaceGradeObjectID: String?
    let notice: String?
    let error: String?
}

/// One section block's server-rendered shell in the suite editor.  Named
/// sections carry a non-empty `sectionID` and `name`; the trailing
/// Ungrouped block has `isUngrouped == true`, a sentinel empty
/// `sectionID`, and no name — the template renders no header for it.
struct SuiteSectionShellRow: Encodable {
    let sectionID: String
    let name: String
    let isUngrouped: Bool
    /// Section-level variables as pre-serialised JSON strings so the
    /// template can emit them into hidden inputs / editable rows without
    /// re-encoding in Leaf (which doesn't handle JSONValue well).  One
    /// `{name, valueJSON}` entry per variable.
    let variables: [SuiteSectionVariableShellRow]
    /// Empty-state flag so the template can hide the "Variables" block
    /// when the section has none (keeps the header clean).
    let hasVariables: Bool
}

struct SuiteSectionVariableShellRow: Encodable {
    let name: String
    /// JSON-encoded value, ready to stuff into an `<input value="">`.
    let valueJSON: String
}

struct CurrentFileLink {
    let name: String
    let url: String
}

struct EditableSuiteRow: Encodable {
    let name: String
    let url: String
    let isTest: Bool
    let tier: String
    let order: Int
    let dependsOn: [String]  // script names of prerequisites; empty == none
    let points: Int  // grade weight; 1 = default (unweighted)
    let displayName: String?  // optional human-readable name shown to students

    /// Empty string when displayName is nil — Leaf doesn't support `??` in templates.
    var displayNameOrEmpty: String { displayName ?? "" }

    /// Display name if set, otherwise the filename stem (extension stripped).
    /// Used as the default value of the name input in the assignment editor.
    var displayNameOrStem: String {
        if let n = displayName, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return n }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// JSON-encoded `dependsOn` array for use as an HTML data attribute in Leaf templates.
    var dependsOnJSON: String {
        let data = (try? JSONEncoder().encode(dependsOn)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    enum CodingKeys: String, CodingKey {
        case name
        case url
        case isTest
        case tier
        case order
        case dependsOn
        case points
        case displayName
        case displayNameOrEmpty
        case displayNameOrStem
        case dependsOnJSON
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(isTest, forKey: .isTest)
        try container.encode(tier, forKey: .tier)
        try container.encode(order, forKey: .order)
        try container.encode(dependsOn, forKey: .dependsOn)
        try container.encode(points, forKey: .points)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encode(displayNameOrEmpty, forKey: .displayNameOrEmpty)
        try container.encode(displayNameOrStem, forKey: .displayNameOrStem)
        try container.encode(dependsOnJSON, forKey: .dependsOnJSON)
    }
}

/// A single row in the suite table representing a pattern family.  Sits
/// alongside `EditableSuiteRow` values — the family expands into N
/// generated scripts at save time, but in the editor UI it's one draggable
/// entry with the family's metadata.
struct FamilySuiteRow: Encodable {
    let id: String
    let name: String
    let functionName: String
    let tier: String  // family default tier
    let caseCount: Int
    let totalPoints: Int  // sum of per-case resolved points

    /// Leaf-friendly formatted case count suffix: "1 case" or "N cases".
    var caseCountText: String { caseCount == 1 ? "1 case" : "\(caseCount) cases" }

    enum CodingKeys: String, CodingKey {
        case id, name, functionName, tier, caseCount, totalPoints, caseCountText
    }

    func encode(to encoder: Encoder) throws {
        // Synthesized Encodable would skip `caseCountText` because it's a
        // computed property; Leaf needs it to render the row subtitle, so
        // we emit it explicitly here.
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(functionName, forKey: .functionName)
        try c.encode(tier, forKey: .tier)
        try c.encode(caseCount, forKey: .caseCount)
        try c.encode(totalPoints, forKey: .totalPoints)
        try c.encode(caseCountText, forKey: .caseCountText)
    }
}

struct AssignmentStudentHistoryContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentID: String
    let assignmentTitle: String
    let studentID: String
    let historyPath: String
    let rows: [AssignmentSubmissionHistoryRow]
}

struct AssignmentSubmissionHistoryRow: Encodable {
    let submissionID: String
    let attemptNumber: Int
    let status: String
    let submittedAt: String
    let gradeText: String
}

/// View context for the per-student, grouped-by-assignment view at
/// `/:courseCode/students/:urlToken/submissions`.  Each `StudentAssignmentRow`
/// mirrors `TestSetupRow` from the student dashboard so the same per-row
/// chrome (status / due / grade / latest submission / badges) renders the
/// same way, with an extra Actions column carrying instructor-only
/// affordances (Retest, inline extension form).
struct CourseStudentSubmissionsContext: Encodable {
    let currentUser: CurrentUserContext?
    let studentName: String
    let studentUsername: String
    let courseCode: String
    let courseName: String
    let backURL: String
    let sections: [StudentAssignmentSectionContext]
    let ungroupedRows: [StudentAssignmentRow]
    let hasSections: Bool
    let hasUngrouped: Bool
}

struct StudentAssignmentSectionContext: Encodable {
    let sectionID: String
    let name: String
    let rows: [StudentAssignmentRow]
}

struct StudentAssignmentRow: Encodable {
    let assignmentID: String
    let title: String
    let status: String  // "open" | "closed"
    let isOpen: Bool
    let dueAtText: String?
    let effectiveDueAtText: String?  // shown when an extension is active
    let hasExtension: Bool
    let extensionFormInput: String  // datetime-local prefill (extension or dueAt)
    let extensionSavePath: String
    let extensionDeletePath: String
    let retestPath: String
    let historyURL: String
    let submissionCount: Int
    let hasLatestSubmission: Bool
    let latestSubmissionID: String
    let latestSubmittedAtText: String
    let additionalSubmissionCount: Int
    let bestGradeText: String?
    let badges: [AchievementBadge]
}

/// Per-student, per-assignment full submission history page.
struct StudentAssignmentHistoryContext: Encodable {
    let currentUser: CurrentUserContext?
    let studentName: String
    let studentUsername: String
    let courseCode: String
    let assignmentID: String
    let assignmentTitle: String
    let backURL: String
    let historyPath: String
    let rows: [AssignmentSubmissionHistoryRow]
}
