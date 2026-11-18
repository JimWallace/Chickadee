// APIServer/MCP/Admin/Tools/GetUsageSummaryTool.swift
//
// Read tool: usage statistics for annual reporting (an APR, a grant or
// program report). How many courses, students, instructors, TAs,
// assignments, submissions and lab openings Chickadee carried across a set of
// academic terms, with a per-term breakdown and optional per-course rows.
// Wraps `UsageStatisticsBuilder`.
//
// Scope: the whole deployment by default, or only the courses the calling
// admin teaches (`scope: "mine"`, an instructor enrollment). Either can be
// narrowed further with `courses`.
//
// PII boundary (code allowlist): the output is `UsageReport`, which holds
// counts, course labels and fixed vocabulary keys only. User IDs are read
// inside the builder to count distinct people and never reach the output;
// per-course student counts under `UsageReport.smallCourseThreshold` are
// withheld. Asserted by the per-tool PII test.

import Core
import Fluent
import Vapor

struct GetUsageSummaryTool: DiagnosticTool {
    /// Which courses a report covers.
    enum Scope: String, CaseIterable, Sendable {
        /// Every course on the deployment.
        case deployment
        /// The courses the calling admin holds an instructor enrollment in.
        case mine
    }

    struct Input: Decodable, Sendable {
        /// A calendar year: its Winter, Spring and Fall terms. Ignored when
        /// `terms` is given. Defaults to the current year.
        var year: Int?
        /// Explicit terms as short labels ("F25", "W26", "S26"), e.g. for an
        /// academic year.
        var terms: [String]?
        /// "deployment" (default) or "mine".
        var scope: String?
        /// Optional course codes or keys ("CS136", "CS136-F26").
        var courses: [String]?
        /// Include one row per course. Default false.
        var includePerCourse: Bool?
    }

    typealias Output = UsageReport

    static let name = "get_usage_summary"
    static let yearRange = 2000...2099
    static let maxTerms = 12
    static let description =
        "Usage statistics for annual reporting (e.g. an APR): course offerings, distinct course "
        + "codes, enrolled and active students, instructors, TAs, assignments by type and by "
        + "language, content items, student submissions by status and source, validation runs, "
        + "lab openings, AI-feedback releases, tournaments, and courses using BrightSpace / LTI / "
        + "AI feedback / GitHub submission. Counted by academic term: a course counts in the term "
        + "it is offered in. Pass year (a calendar year: its Winter, Spring and Fall terms; default "
        + "the current year) or terms (short labels such as [\"F25\",\"W26\",\"S26\"] for an "
        + "academic year). scope \(MCPEnumProse<Scope>.quotedOrList): deployment (default) counts "
        + "every course; mine counts only courses where you hold an instructor enrollment. Optional "
        + "courses (codes or keys) narrows further; includePerCourse adds one row per course. "
        + "Returns totals, a per-term breakdown and notes on how to read the numbers. Read-only; "
        + "aggregate counts only — no student identities, grades, or submission contents, and "
        + "per-course student counts below \(UsageReport.smallCourseThreshold) are withheld."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "year": .object([
                "type": .string("integer"),
                "minimum": .int(yearRange.lowerBound),
                "maximum": .int(yearRange.upperBound),
                "description": .string(
                    "Calendar year to report on (its Winter, Spring and Fall terms). Default: the "
                        + "current year. Ignored when terms is given."),
            ]),
            "terms": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "maxItems": .int(maxTerms),
                "description": .string(
                    "Explicit terms as short labels, e.g. [\"F25\", \"W26\", \"S26\"] (W = Winter, "
                        + "S = Spring, F = Fall)."),
            ]),
            "scope": .object([
                "type": .string("string"),
                "enum": MCPEnumProse<Scope>.jsonEnum,
                "description": .string(
                    "deployment (default): every course. mine: only courses where you hold an "
                        + "instructor enrollment."),
            ]),
            "courses": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string(
                    "Optional course codes or keys to narrow to, e.g. [\"CS136\", \"CS135-F26\"] "
                        + "(case-insensitive)."),
            ]),
            "includePerCourse": .object([
                "type": .string("boolean"),
                "description": .string("Include one row per course offering. Default false."),
            ]),
        ]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        let terms = try Self.resolveTerms(input)
        let scope = try MCPEnumProse<Scope>.parseOptional(input.scope, field: "scope") ?? .deployment
        var instructorID: UUID?
        if scope == .mine {
            instructorID = try await context.requireAdminSubject().requireID()
        }
        let courses = input.courses?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let request = UsageReportRequest(
            terms: terms, instructorUserID: instructorID,
            courseKeys: (courses?.isEmpty ?? true) ? nil : courses,
            includePerCourse: input.includePerCourse ?? false)
        do {
            return try await UsageStatisticsBuilder.report(request, on: context.db)
        } catch UsageStatisticsError.requiresSQLDatabase {
            throw MCPToolError.executionFailed(detail: "the usage summary needs a SQL database")
        }
    }

    /// The terms `input` names: its `terms`, else the three of `year`, else
    /// the three of the current year.
    static func resolveTerms(_ input: Input, now: Date = Date()) throws -> [AcademicTerm] {
        if let labels = input.terms, !labels.isEmpty {
            guard labels.count <= maxTerms else {
                throw MCPToolError.invalidArguments(detail: "terms may list at most \(maxTerms) terms.")
            }
            return try labels.map { label in
                guard let term = AcademicTerm(shortLabel: label) else {
                    throw MCPToolError.invalidArguments(
                        detail: "'\(label)' is not a term label; use e.g. \"F25\", \"W26\" or \"S26\".")
                }
                return term
            }
        }
        let year = input.year ?? currentYear(at: now)
        guard yearRange.contains(year) else {
            throw MCPToolError.invalidArguments(
                detail: "year must be between \(yearRange.lowerBound) and \(yearRange.upperBound).")
        }
        return AcademicTerm.terms(ofCalendarYear: year)
    }

    private static func currentYear(at date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto") ?? .current
        return calendar.component(.year, from: date)
    }
}
