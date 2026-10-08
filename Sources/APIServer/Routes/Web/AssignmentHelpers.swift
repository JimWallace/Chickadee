// APIServer/Routes/Web/AssignmentHelpers.swift
//
// Small free functions used by the instructor assignment routes that
// don't belong to a more focused helper file.  The bulk of what used to
// live here was split out per issue #442 into:
//
//   - AssignmentDraftHelpers.swift (now in Helpers/, #2142)
//   - AssignmentRequirementHelpers.swift
//   - AssignmentSlugHelpers.swift (now in Helpers/, #2143)
//   - ManifestFileHelpers.swift (now in Helpers/, #1726)
//   - MultipartHelpers.swift
//   - NotebookScaffoldHelpers.swift (now in Helpers/, #2142)
//   - RunnerValidationHelpers.swift (now Services/RunnerValidationService.swift, #2140)
//   - SuiteRowHelpers.swift
//   - TestSetupZipHelpers.swift (now in Helpers/, #1726)
//
// What remains: due-date parsing/formatting,
// human-name splitting, return-path sanitization,
// sort-order allocation, grade-extraction helpers, CSV
// escaping, and student-ID name inference.

import Core
import Fluent
import Foundation
import Vapor

func parseDueDate(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }

    let iso = ISO8601DateFormatter()
    if let d = iso.date(from: raw) { return d }

    // Accept both `datetime-local` shapes (with and without seconds) — this
    // is the ONE parser for instructor-entered local datetimes; the
    // extension-grant form used to carry its own copy, the v0.4.82
    // five-drifted-display-sites bug class (#1118).
    for pattern in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "America/Toronto")
        fmt.dateFormat = pattern
        if let d = fmt.date(from: raw) { return d }
    }
    return nil
}

func splitHumanName(_ raw: String?) -> (surname: String, givenNames: String)? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.contains(",") {
        let parts = trimmed.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        let surname = String(parts.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let givenNames =
            parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return (
            surname.isEmpty ? "—" : surname,
            givenNames.isEmpty ? "—" : givenNames
        )
    }

    let parts = trimmed.split(whereSeparator: \.isWhitespace)
    guard !parts.isEmpty else { return nil }
    if parts.count == 1 {
        return ("—", String(parts[0]))
    }

    let surname = String(parts.last ?? "")
    let givenNames = parts.dropLast().joined(separator: " ")
    return (
        surname.isEmpty ? "—" : surname,
        givenNames.isEmpty ? "—" : givenNames
    )
}

/// The optional `returnTo` field every per-student staff action form posts.
struct AssignmentReturnTo: Content {
    var returnTo: String?
}

extension Request {
    /// Redirects to the form's `returnTo` when it points back inside this
    /// assignment's instructor pages, else to the submissions list.
    func redirectToAssignmentReturnPath(assignmentIDRaw: String, returnTo: String?) -> Response {
        redirect(
            to: sanitizedAssignmentReturnPath(
                returnTo,
                assignmentIDRaw: assignmentIDRaw,
                fallbackPath: "/instructor/\(assignmentIDRaw)/submissions"))
    }

    /// `redirectToAssignmentReturnPath` for a handler that has not decoded
    /// its form body: reads the `returnTo` field itself.
    func redirectToAssignmentReturnPath(assignmentIDRaw: String) -> Response {
        let body = try? content.decode(AssignmentReturnTo.self)
        return redirectToAssignmentReturnPath(assignmentIDRaw: assignmentIDRaw, returnTo: body?.returnTo)
    }
}

func sanitizedAssignmentReturnPath(
    _ raw: String?,
    assignmentIDRaw: String,
    fallbackPath: String
) -> String {
    guard let path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/") else {
        return fallbackPath
    }

    let expectedPrefix = "/instructor/\(assignmentIDRaw)"
    guard path == expectedPrefix || path.hasPrefix(expectedPrefix + "/") else {
        return fallbackPath
    }
    return path
}

func dueAtLocalInputString(_ date: Date?) -> String {
    guard let date else { return "" }
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "America/Toronto")
    fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
    return fmt.string(from: date)
}

/// The grade percent recorded on a submission result: weighted when present,
/// else passed tests over all tests.
func gradePercentFromCollectionJSON(_ collectionJSON: String) -> Int? {
    CollectionGradeFields(json: collectionJSON)?.gradePercent
}

/// Formats a (possibly fractional) points value for display: whole numbers show
/// without a decimal ("3"), partial credit shows up to two trimmed decimals
/// ("2.75", "2.5").
func formatPoints(_ value: Double) -> String {
    let rounded = (value * 100).rounded() / 100
    if rounded == rounded.rounded() {
        return String(Int(rounded.rounded()))
    }
    var s = String(format: "%.2f", rounded)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}

func csvEscaped(_ value: String) -> String {
    if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return value
}

func inferNameFromStudentID(_ studentID: String) -> (surname: String, givenNames: String) {
    let raw = studentID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return ("—", "—") }

    if let parsed = splitHumanName(raw), raw.contains(",") { return parsed }
    return ("—", "—")
}

// MARK: - Assignment resolution
//
// Moved here from SuiteEditHelpers.swift (#1717): the write loaders have
// 39 callers in 21 files, almost none of them suite editing.

/// Loads the (assignment, setup) pair from a `:assignmentID` path
/// parameter.  Throws `.notFound` if either the assignment or its
/// referenced test setup is missing.
///
/// Performs **no authorization** — private so unauthorized use is impossible
/// outside this file. Handlers go through `loadAssignmentAndSetupForStaffRead`
/// or `loadAssignmentAndSetupForWrite`, which scope the caller to the
/// assignment's own course (#1103).
private func loadAssignmentAndSetup(_ req: Request) async throws -> (APIAssignment, APITestSetup) {
    let idStr = try assignmentPublicIDParameter(from: req)
    guard
        let assignment = try await assignmentByPublicID(idStr, on: req.db),
        let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
    else { throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'") }
    return (assignment, setup)
}

/// Lighter sibling of `loadAssignmentAndSetup(_:)` for handlers that never
/// touch the test setup — same `:assignmentID` resolution and 404 message,
/// without forcing an unnecessary `APITestSetup` fetch.  Handlers that need
/// the raw path parameter afterwards can use `assignment.publicID`, which
/// is always identical to it (`assignmentByPublicID` is an exact-match
/// filter on a validated parameter).
///
/// Performs **no authorization** by itself. Callers must either go through
/// `loadAssignmentForStaffRead` / `loadAssignmentForWrite`, or — like
/// `resolveStudentAssignmentAction` and `moveToSection` — apply their own
/// per-course gate immediately after loading (#1103).
func loadAssignment(_ req: Request) async throws -> APIAssignment {
    let idStr = try assignmentPublicIDParameter(from: req)
    guard let assignment = try await assignmentByPublicID(idStr, on: req.db) else {
        throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
    }
    return assignment
}

/// Read-authorizing sibling of `loadAssignmentAndSetup(_:)`. After loading,
/// requires the caller hold at least a `.ta` role in the assignment's **own**
/// course (`requireCourseRole`, admin bypass). Unlike the write loader there is
/// no archived-course block, so archived courses stay readable for audits.
///
/// The editor read handlers (suite/scripts/files/achievements/datasets/
/// global-variables/edit-page) use this so a staff member of course A can't
/// fetch course B's reference solution or secret tests by guessing its 6-char
/// assignment public ID — the same cross-course hole #417 Slice G closed on
/// the API side (`downloadTestSetup`), missed on the web editor (#1103).
func loadAssignmentAndSetupForStaffRead(_ req: Request) async throws -> (APIAssignment, APITestSetup) {
    let (assignment, setup) = try await loadAssignmentAndSetup(req)
    let caller = try req.auth.require(APIUser.self)
    try await requireCourseRole(caller: caller, courseID: assignment.courseID, atLeast: .ta, db: req.db)
    return (assignment, setup)
}

/// Read-authorizing sibling of `loadAssignment(_:)` — same `.ta` staff gate as
/// `loadAssignmentAndSetupForStaffRead`, for read-only pages that never touch
/// the test setup (per-assignment submissions list, per-student history). No
/// archived-course block, so archived courses stay auditable (#1103).
func loadAssignmentForStaffRead(_ req: Request) async throws -> APIAssignment {
    let assignment = try await loadAssignment(req)
    let caller = try req.auth.require(APIUser.self)
    try await requireCourseRole(caller: caller, courseID: assignment.courseID, atLeast: .ta, db: req.db)
    return assignment
}

/// Write-authorizing sibling of `loadAssignmentAndSetup(_:)`. After loading,
/// authorizes the caller for a *write* to the assignment's **own** course via
/// `requireCourseWriteAccess` (per-course role + admin bypass + archived-course
/// block). Mutating editor handlers use this so a write is scoped to the
/// resource's course rather than the caller's active course — closing both the
/// archived-course and cross-course write paths the `/instructor` group
/// middleware can't see (see docs/multi-course-roles.md).
///
/// Callers state their floor explicitly (#1113): the assignment **content**
/// editor handlers (suite/scripts/sections/families/checks/global-inputs/
/// datasets/achievements/notebook/solution/save-edit/retest-all) pass `.ta` —
/// all of which a TA may do. The one structural caller, `cloneAssignment`
/// (it creates a new assignment), passes `.instructor` (#417 Slice E).
func loadAssignmentAndSetupForWrite(
    _ req: Request, atLeast: CourseRole
) async throws -> (APIAssignment, APITestSetup) {
    let (assignment, setup) = try await loadAssignmentAndSetup(req)
    let caller = try req.auth.require(APIUser.self)
    try await requireCourseWriteAccess(
        caller: caller, courseID: assignment.courseID, atLeast: atLeast, db: req.db)
    // Content-versioning seam: seeds the pre-edit baseline and registers the
    // setup so `AssignmentVersionCaptureMiddleware` snapshots it if this
    // request succeeds. Handlers that turn out not to change content cost
    // nothing — the snapshot dedupes to no row.
    await req.beginAssignmentContentEdit(setup: setup)
    return (assignment, setup)
}

/// Write-authorizing sibling of `loadAssignment(_:)`, for handlers that mutate
/// per-course state but never touch the test setup. Same `requireCourseWriteAccess`
/// gate as `loadAssignmentAndSetupForWrite`, scoping the write to the
/// assignment's **own** course (#417, follow-up to Slice A).
///
/// Callers state their floor explicitly (#1113): per-student grading actions
/// (retest/reset/grade-override — TA-allowed) pass `.ta`; assignment-lifecycle
/// actions (open/close/status/delete/BrightSpace — instructor-only) pass
/// `.instructor` (#417 Slice E).
func loadAssignmentForWrite(
    _ req: Request, atLeast: CourseRole
) async throws -> APIAssignment {
    let assignment = try await loadAssignment(req)
    let caller = try req.auth.require(APIUser.self)
    try await requireCourseWriteAccess(
        caller: caller, courseID: assignment.courseID, atLeast: atLeast, db: req.db)
    return assignment
}
