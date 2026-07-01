// APIServer/MCP/Admin/Tools/GetInstructorCardSeriesTool.swift
//
// Read tool: the time-series (sparkline) data behind the instructor dashboard's
// four diagnostic cards for one course — submissions, active students, active
// assignments, and browser errors — across all three windows (24h / 7d / 30d).
// Wraps the same builder the instructor dashboard polls
// (`GET /instructor/metrics/cards`, `instructorCardSeries`), scoped to the
// course identified by `courseCode`.
//
// PII boundary (code allowlist — the shipped guarantee, no DB role): the
// instructor surface is course-scoped by the human's enrollment; this admin
// surface is deployment-wide, so the tool takes the course code as an explicit
// query filter rather than a session. The returned payload is PER-BUCKET COUNTS
// only — submissions, distinct-student COUNT, distinct-assignment COUNT, and
// browser-error count — never a student identifier. The enrolled-student / setup
// lookup is an internal scoping step; no identity reaches the output, asserted
// by a per-tool PII test.

import Core
import Fluent
import Vapor

struct GetInstructorCardSeriesTool: DiagnosticTool {
    struct Input: Decodable, Sendable {
        /// The course to scope the series to (e.g. "CS136"). Matched
        /// case-insensitively against active (non-archived) courses.
        var courseCode: String
    }

    /// The existing dashboard sparkline payload, reused verbatim — aggregate
    /// per-bucket counts only, no row-level identifiers.
    typealias Output = InstructorCardSeriesResponse

    static let name = "get_instructor_card_series"
    static let description =
        "Time-series (sparkline) data behind the instructor dashboard's four cards for one course: "
        + "per-bucket student submissions, active students (distinct count), active assignments "
        + "(distinct count), and browser errors. Requires courseCode (e.g. \"CS136\", matched "
        + "case-insensitively). Returns every selectable window in one payload (24h = 24 hourly "
        + "buckets, 7d = 28 six-hour buckets, 30d = 30 daily buckets), each with bucket labels, a "
        + "headline, and the per-bucket series. Read-only; aggregate counts only — no student "
        + "identities, grades, or submission contents."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": .object([
                "type": .string("string"),
                "description": .string(
                    "Course code to scope the series to, e.g. \"CS136\" (case-insensitive)."),
            ])
        ]),
        "required": .array([.string("courseCode")]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        try await context.requireAdminSubject(tool: Self.name)

        let code = input.courseCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            throw MCPToolError.invalidArguments(tool: Self.name, detail: "courseCode must not be empty.")
        }
        guard
            let course = try await findActiveCourse(byCode: code, on: context.db),
            let courseUUID = course.id
        else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "No active course with code '\(code)'.")
        }

        let setupIDs = try await APITestSetup.query(on: context.db)
            .filter(\.$courseID == courseUUID)
            .all()
            .compactMap(\.id)

        let studentIDs = try await enrolledStudentIDs(courseUUID: courseUUID, on: context.db)

        return try await context.request.application.diagnostics.instructorCardSeries(
            setupIDs: setupIDs, studentIDs: studentIDs, on: context.db)
    }

    /// The course's enrolled students, matching the instructor dashboard's
    /// scoping (`InstructorDashboardRoutes+Cards`).  Empty when the course has
    /// no enrollments.
    private func enrolledStudentIDs(courseUUID: UUID, on db: any Database) async throws -> Set<UUID> {
        // Students are `.student`-role enrollments now (#417 Slice G2).
        try await studentUserIDsInCourse(courseUUID, on: db)
    }
}
