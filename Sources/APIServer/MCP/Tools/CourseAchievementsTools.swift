// APIServer/MCP/Tools/CourseAchievementsTools.swift
//
// Read and write tools for a course's achievements (docs/achievement-rewards.md,
// S5): the badges that count a student's work across the course's
// assignments. content:read and content:write, course-scoped. They mirror
// `GET` and `PUT /instructor/achievements/rows` and run the same
// `AchievementsEditing` course path, so the same validation runs.
//
// Neither tool reports who earned what. The award ledger is student data;
// "Earned so far" is on the web tab only.

import Core
import Fluent
import Foundation

// MARK: - get_course_achievements

struct GetCourseAchievementsTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
    }

    struct Output: Encodable, Sendable {
        let courseCode: String
        /// The key and term of the course acted on; see `MCPSchema.courseKeyOutput`.
        let courseKey: String
        let courseTerm: String?
        let achievements: [AchievementRow]
    }

    static let name = "get_course_achievements"
    static let description =
        "Get a course's achievements: the badges that count a student's work across the course's "
        + "assignments, identified by course code. Each row is an individual badge whose conditions "
        + "count assignments (" + MCPAchievementSignalProse.courseCommaList + "), optionally over "
        + "one course section, one concept or a list of assignments. Read-only; edit with "
        + "update_course_achievements. Course achievements change no grade."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["courseCode": MCPSchema.courseCode]),
        "required": .array([.string("courseCode")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = courseAchievementsOutputSchema
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let course = try await resolveCourse(code: input.courseCode, context: context)
        return Output(
            courseCode: course.code, courseKey: course.urlKey, courseTerm: course.term?.displayName,
            achievements: AchievementsEditing.rows(fromCourse: course))
    }
}

// MARK: - update_course_achievements

struct UpdateCourseAchievementsTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
        /// The full desired list. Replaces the existing list wholesale; send
        /// `[]` to clear every course achievement.
        let achievements: [AchievementRow]
    }

    typealias Output = GetCourseAchievementsTool.Output

    static let name = "update_course_achievements"
    static let description =
        "Replace a course's achievements by course code. Provide the full desired list; it is "
        + "replaced wholesale, not merged. Send [] to clear every course achievement. Each row needs a "
        + "`name`, the scope `individual`, and at least one condition. A condition counts assignments "
        + "with one signal (" + MCPAchievementSignalProse.courseCommaList + "), takes the comparator "
        + "atLeast and a whole number of at least 1, and may count over one set with targetKind ("
        + courseTargetKinds.joined(separator: ", ") + ") and targetRef (a course section by id or "
        + "name, an assignment concept, or comma-separated assignment public IDs). "
        + "assignmentsAtGrade needs gradeFloor (0–100); achievementsEarned may name one assignment "
        + "achievement id in achievementRef. Targets are validated against the course; ids must be "
        + "unique. Use get_course_achievements first to read the current list, and keep each existing "
        + "row's id: a row sent without its id is a new achievement that students earn again. Course "
        + "achievements change no grade, so nothing is re-graded."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.courseCode,
            "achievements": .object([
                "type": .string("array"),
                "description": .string(
                    "The full desired course achievements list; replaces the existing list. Send [] to clear."),
                "items": courseAchievementRowSchema,
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("achievements")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = courseAchievementsOutputSchema
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: true, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let course = try await resolveCourseForWrite(code: input.courseCode, context: context, atLeast: .ta)
        let rows: [AchievementRow]
        do {
            rows = try await AchievementsEditing.apply(rows: input.achievements, course: course, on: context.db)
        } catch let error as WebAssignmentError where error.isClientRefusal {
            throw MCPToolError.from(error)
        }
        return Output(
            courseCode: course.code, courseKey: course.urlKey, courseTerm: course.term?.displayName,
            achievements: rows)
    }
}

// MARK: - Schemas

/// The target kinds that name a set of a course's assignments.
private let courseTargetKinds = TargetKind.allCases.filter(\.namesCourseAssignments).map(\.rawValue)

private let courseAchievementsOutputSchema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
        "courseCode": MCPSchema.string,
        "courseKey": MCPSchema.courseKeyOutput,
        "courseTerm": MCPSchema.courseTermOutput,
        "achievements": .object([
            "type": .string("array"),
            "items": courseAchievementRowSchema,
        ]),
    ]),
    "required": .array([.string("courseCode"), .string("courseKey"), .string("achievements")]),
])

/// The id property of a course row: the row's identity in the award ledger.
private let courseRowIDProperty: JSONValue = .object([
    "type": .string("string"),
    "description": .string(
        "Stable row id; omit on a new row and the server assigns one. Keep the id of every "
            + "existing row: a student who earned it keeps the award, and a row sent without "
            + "its id is a new achievement that students earn again."),
])

private let courseTargetRefDescription =
    "courseSection: a course section id or name. concept: one of "
    + AssignmentConcept.allCases.map(\.rawValue).joined(separator: ", ")
    + ". assignments: comma-separated assignment public IDs."

private let courseSignalProperty: JSONValue = .object([
    "type": .string("string"),
    "enum": .array(AchievementSignalValues.at(.course).map(JSONValue.string)),
    "description": .string(MCPAchievementSignalProse.courseUnitsClause + "."),
])

private let courseComparatorProperty: JSONValue = .object([
    "type": .string("string"),
    "enum": .array([.string(ConditionComparator.atLeast.rawValue)]),
])

private let courseValueProperty: JSONValue = .object([
    "type": .string("integer"),
    "minimum": .int(1),
    "description": .string("The count to reach: a whole number of at least 1."),
])

private let courseTargetKindProperty: JSONValue = .object([
    "type": .string("string"),
    "enum": .array(courseTargetKinds.map(JSONValue.string)),
    "description": .string("The set of assignments to count over. Omit for every assignment."),
])

private let courseGradeFloorProperty: JSONValue = .object([
    "type": .string("number"),
    "description": .string("assignmentsAtGrade only: the best-grade percent (0–100) to reach."),
])

private let courseAchievementRefProperty: JSONValue = .object([
    "type": .string("string"),
    "description": .string(
        "achievementsEarned only: the assignment achievement id to count (see get_achievements). Omit to count any."),
])

/// The properties of one course condition.
private let courseConditionProperties: JSONValue = .object([
    "signal": courseSignalProperty,
    "comparator": courseComparatorProperty,
    "value": courseValueProperty,
    "targetKind": courseTargetKindProperty,
    "targetRef": .object(["type": .string("string"), "description": .string(courseTargetRefDescription)]),
    "gradeFloor": courseGradeFloorProperty,
    "achievementRef": courseAchievementRefProperty,
])

/// One course `AchievementRow`: an individual badge over the course signals.
/// The class and record fields of the assignment row are not offered,
/// because the course level refuses them.
private let courseAchievementRowSchema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
        "id": courseRowIDProperty,
        "name": AchievementRowSchemaParts.name,
        "detail": AchievementRowSchemaParts.detail,
        "scope": .object([
            "type": .string("string"),
            "enum": .array([.string(AchievementScope.individual.rawValue)]),
            "description": .string("individual: a course achievement is a per-student badge."),
        ]),
        "match": AchievementRowSchemaParts.match,
        "conditions": .object([
            "type": .string("array"),
            "description": .string("At least one count over the course's assignments."),
            "items": .object([
                "type": .string("object"),
                "properties": courseConditionProperties,
                "required": .array([.string("signal"), .string("comparator"), .string("value")]),
                "additionalProperties": .bool(false),
            ]),
        ]),
    ]),
    "required": .array([.string("name"), .string("scope"), .string("conditions")]),
    "additionalProperties": .bool(false),
])
