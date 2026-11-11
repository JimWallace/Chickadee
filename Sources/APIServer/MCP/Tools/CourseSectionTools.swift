// APIServer/MCP/Tools/CourseSectionTools.swift
//
// Tools for *course* sections — the named groups that organize an assignment
// list (e.g. "Labs", "Assignments", "Exams"), distinct from the test-suite
// sections inside a single assignment (create_suite_section / move_suite_item).  A
// course section (`APICourseSection`) has a name and a sort order, and names no
// type or grading mode; an assignment belongs to at most one via its
// nullable `sectionID`.  content:read for the listing, content:write for the
// rest.
//
// These share their field rules and writes with the web instructor dashboard
// handlers (`CourseAdminRoutes+Sections.swift`) through `CourseSectionService`
// (#2769): create_course_section ~ createSection, set_assignment_course_section
// ~ moveToSection.  A move changes neither the assignment's type nor its
// grading mode (docs/assignment-types.md).  This is assignment-organization
// metadata, not student/enrollment data.

import Core
import Fluent
import Foundation

// MARK: - list_course_sections

struct ListCourseSectionsTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
    }

    struct Output: Encodable, Sendable {
        struct Section: Encodable, Sendable {
            let sectionID: String
            let name: String
            let sortOrder: Int
        }
        let courseCode: String
        /// The key and term of the course acted on; see `MCPSchema.courseKeyOutput`.
        let courseKey: String
        let courseTerm: String?
        let sections: [Section]
    }

    static let name = "list_course_sections"
    static let description =
        "List the course sections (assignment groups like \"Labs\" or \"Assignments\") for a course, "
        + "identified by course code, in display order. Returns each section's id (use it as "
        + "set_assignment_course_section's courseSectionID), name and sort order. A section names no type "
        + "and no grading mode: grading follows each "
        + "assignment's declared type. These are course-level groups for organizing the assignment list — not the "
        + "test-suite sections inside an assignment (those come from get_suite)."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.courseCode
        ]),
        "required": .array([.string("courseCode")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.string,
            "courseKey": MCPSchema.courseKeyOutput,
            "courseTerm": MCPSchema.courseTermOutput,
            "sections": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "sectionID": MCPSchema.string,
                        "name": MCPSchema.string,
                        "sortOrder": MCPSchema.integer,
                    ]),
                    "required": .array([
                        .string("sectionID"), .string("name"), .string("sortOrder"),
                    ]),
                ]),
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("courseKey"), .string("sections")]),
    ])
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let course = try await resolveCourse(code: input.courseCode, context: context)
        let courseID = try course.requireID()
        let sections = try await APICourseSection.query(on: context.db)
            .filter(\.$courseID == courseID)
            .sort(\.$sortOrder)
            .all()
        let rows = sections.compactMap { section -> Output.Section? in
            guard let id = section.id else { return nil }
            return Output.Section(
                sectionID: id.uuidString,
                name: section.name,
                sortOrder: section.sortOrder)
        }
        return Output(
            courseCode: course.code, courseKey: course.urlKey, courseTerm: course.term?.displayName,
            sections: rows)
    }
}

// MARK: - create_course_section

struct CreateCourseSectionTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
        let name: String
    }

    struct Output: Encodable, Sendable {
        let courseCode: String
        /// The key and term of the course acted on; see `MCPSchema.courseKeyOutput`.
        let courseKey: String
        let courseTerm: String?
        let sectionID: String
        let name: String
        let sortOrder: Int
    }

    static let name = "create_course_section"
    static let description =
        "Create a new course section (an assignment group like \"Labs\") in a course, by course code. "
        + "Provide a name. A section names no type: create_assignment declares each assignment's own. "
        + "Grading follows the type, so the section sets no grading mode, and moving an assignment into it "
        + "changes neither the type nor the grading. The new section is appended after the existing ones. Returns its id for use with set_assignment_course_section."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.courseCode,
            "name": .object([
                "type": .string("string"),
                "description": .string("Display name for the new section (non-empty), e.g. \"Labs\"."),
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("name")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.string,
            "courseKey": MCPSchema.courseKeyOutput,
            "courseTerm": MCPSchema.courseTermOutput,
            "sectionID": MCPSchema.string,
            "name": MCPSchema.string,
            "sortOrder": MCPSchema.integer,
        ]),
        "required": .array([
            .string("courseCode"), .string("courseKey"), .string("sectionID"), .string("name"),
            .string("sortOrder"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let draft: CourseSectionDraft
        do {
            draft = try CourseSectionDraft(name: input.name)
        } catch {
            throw mcpToolError(error)
        }
        let course = try await resolveCourseForWrite(
            code: input.courseCode, context: context, atLeast: CourseRoleFloor.manageSections)
        let section = try await CourseSectionService.create(draft, courseID: try course.requireID(), on: context.db)

        return Output(
            courseCode: course.code, courseKey: course.urlKey, courseTerm: course.term?.displayName,
            sectionID: try section.requireID().uuidString,
            name: section.name,
            sortOrder: section.sortOrder)
    }
}

// MARK: - set_assignment_course_section

struct SetAssignmentCourseSectionTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// Course-section id (from list_course_sections); "" / "none" / omitted ungroups.
        let courseSectionID: String?
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        /// The section the assignment now belongs to; "" when ungrouped.
        let sectionID: String
        let sectionName: String?
        /// The assignment's grading mode, which a move never changes.
        let gradingMode: String?
    }

    static let name = "set_assignment_course_section"
    static let description =
        "Place an assignment into a course section (assignment group like \"Labs\"), or ungroup it, by "
        + "assignment public ID. courseSectionID comes from list_course_sections; pass \"\" (or omit) "
        + "to ungroup. A move changes neither the assignment's declared type nor its grading mode, which "
        + "follows the type; update_assignment changes the type. This is organizational metadata and does not "
        + "re-run validation "
        + "or change the open/closed state."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "courseSectionID": .object([
                "type": .string("string"),
                "description": .string(
                    "Target course-section id (from list_course_sections), or \"\" to ungroup."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "sectionID": MCPSchema.string,
            "sectionName": MCPSchema.string,
            "gradingMode": MCPSchema.string,
        ]),
        "required": .array([.string("assignmentPublicID"), .string("sectionID")]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        // Placing an assignment into a course section is instructor-level (#417).
        let assignment = try await context.authorizedAssignmentForWrite(
            publicID: input.assignmentPublicID, atLeast: CourseRoleFloor.manageSections)

        // Resolve + validate the target section against this assignment's course.
        // A non-empty id that doesn't resolve is rejected rather than silently
        // ungrouping, so a typo'd id surfaces as an error to the agent.
        let resolvedSectionID = try await resolveCourseSectionID(
            input.courseSectionID, inCourse: assignment.courseID, owner: "assignment", context: context)

        // Appends to the destination lane, as the web moveToSection does. The
        // type and the grading mode stay as they were.
        let moved = try await CourseSectionService.moveAssignment(
            assignment, toSection: resolvedSectionID, on: context.db)

        return Output(
            assignmentPublicID: assignment.publicID,
            sectionID: resolvedSectionID?.uuidString ?? "",
            sectionName: moved.section?.name,
            gradingMode: moved.gradingMode)
    }

}

// MARK: - rename_course_section

struct RenameCourseSectionTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseSectionID: String
        /// The new display name.
        let name: String
    }

    struct Output: Encodable, Sendable {
        let sectionID: String
        let name: String
        let sortOrder: Int
    }

    static let name = "rename_course_section"
    static let description =
        "Rename a course section (assignment group like \"Labs\") by course-section id (from "
        + "list_course_sections). A rename changes neither the type nor the grading of any assignment "
        + "in it. This is a course section (assignment "
        + "group), not a test-suite section inside an assignment — use rename_suite_section for those."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "courseSectionID": .object([
                "type": .string("string"),
                "description": .string("Course-section id (from list_course_sections)."),
            ]),
            "name": .object([
                "type": .string("string"),
                "description": .string("New display name (non-empty)."),
            ]),
        ]),
        "required": .array([.string("courseSectionID"), .string("name")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "sectionID": MCPSchema.string,
            "name": MCPSchema.string,
            "sortOrder": MCPSchema.integer,
        ]),
        "required": .array([
            .string("sectionID"), .string("name"), .string("sortOrder"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let section = try await resolveCourseSectionForEdit(
            sectionID: input.courseSectionID, context: context, atLeast: CourseRoleFloor.manageSections)
        let edit: CourseSectionEdit
        do {
            edit = try CourseSectionEdit(name: input.name)
        } catch {
            throw mcpToolError(error)
        }
        try await CourseSectionService.update(section, with: edit, on: context.db)
        return Output(
            sectionID: try section.requireID().uuidString,
            name: section.name,
            sortOrder: section.sortOrder)
    }
}

// MARK: - delete_course_section

struct DeleteCourseSectionTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseSectionID: String
    }

    struct Output: Encodable, Sendable {
        let sectionID: String
        /// false when no section with that id existed (idempotent no-op).
        let removed: Bool
        /// How many assignments were ungrouped (their section_id cleared) as a
        /// result of the delete (FK SET NULL).
        let ungroupedAssignmentCount: Int
    }

    static let name = "delete_course_section"
    static let description =
        "Delete a course section (assignment group like \"Labs\"), by course-section id (from "
        + "list_course_sections). Assignments in the section are NOT deleted — they are ungrouped (their "
        + "section link is cleared) and keep their current grading mode. This is a course section, not a "
        + "test-suite section inside an assignment — use delete_suite_section for those. Idempotent: deleting "
        + "an id that no longer exists reports removed=false."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "courseSectionID": .object([
                "type": .string("string"),
                "description": .string("Course-section id (from list_course_sections)."),
            ])
        ]),
        "required": .array([.string("courseSectionID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "sectionID": MCPSchema.string,
            "removed": MCPSchema.boolean,
            "ungroupedAssignmentCount": MCPSchema.integer,
        ]),
        "required": .array([
            .string("sectionID"), .string("removed"), .string("ungroupedAssignmentCount"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: true, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let raw = input.courseSectionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: raw) else {
            throw MCPToolError.invalidArguments(detail: "courseSectionID \"\(raw)\" is not a valid id.")
        }
        // An unknown id is an idempotent no-op (removed=false), and so is a
        // section in a course the account is not enrolled in, so the answer
        // does not tell "does not exist" from "in a course you cannot see"
        // (#2342). A visible course still refuses a role that is too low.
        guard let section = try await APICourseSection.find(uuid, on: context.db),
            try await context.subjectIsEnrolled(in: section.courseID)
        else {
            return Output(sectionID: raw, removed: false, ungroupedAssignmentCount: 0)
        }
        // Deleting a course section is instructor-level structure (#417); archived blocked too.
        try await context.authorizeCourseWriteAccess(
            section.courseID, atLeast: CourseRoleFloor.manageSections)
        // FK SET NULL: assignments in this section have section_id → NULL.
        let ungrouped = try await CourseSectionService.delete(section, on: context.db)
        return Output(sectionID: raw, removed: true, ungroupedAssignmentCount: ungrouped)
    }
}

// MARK: - reorder_course_sections

struct ReorderCourseSectionsTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
        /// The course's section ids in the new display order — must be a
        /// permutation of the course's current sections.
        let orderedSectionIDs: [String]
    }

    struct Output: Encodable, Sendable {
        struct Section: Encodable, Sendable {
            let sectionID: String
            let name: String
            let sortOrder: Int
        }
        let courseCode: String
        /// The key and term of the course acted on; see `MCPSchema.courseKeyOutput`.
        let courseKey: String
        let courseTerm: String?
        let sections: [Section]
    }

    static let name = "reorder_course_sections"
    static let description =
        "Set the display order of a course's sections (assignment groups), by course code. "
        + "orderedSectionIDs must list exactly the course's current section ids (from "
        + "list_course_sections) in the desired order — a permutation, not a subset. Returns the "
        + "sections in their new order. Reorders course sections only; to order tests inside an "
        + "assignment use move_suite_item."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.courseCode,
            "orderedSectionIDs": .object([
                "type": .string("array"),
                "items": MCPSchema.string,
                "description": .string(
                    "The course's section ids in the new order (a permutation of all of them)."),
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("orderedSectionIDs")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.string,
            "courseKey": MCPSchema.courseKeyOutput,
            "courseTerm": MCPSchema.courseTermOutput,
            "sections": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "sectionID": MCPSchema.string,
                        "name": MCPSchema.string,
                        "sortOrder": MCPSchema.integer,
                    ]),
                    "required": .array([
                        .string("sectionID"), .string("name"), .string("sortOrder"),
                    ]),
                ]),
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("courseKey"), .string("sections")]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let course = try await resolveCourseForWrite(
            code: input.courseCode, context: context, atLeast: SortOrderRenumbering.roleFloor)
        let sections: [APICourseSection]
        do {
            let ids = try input.orderedSectionIDs.map(SortOrderRenumbering.sectionID)
            sections = try await SortOrderRenumbering.renumberSections(
                ids, inCourse: try course.requireID(), on: context.db)
        } catch let error as ReorderError {
            throw MCPToolError.invalidArguments(detail: "orderedSectionIDs: \(error.reason)")
        }
        let ordered = try sections.map { section in
            Output.Section(
                sectionID: try section.requireID().uuidString, name: section.name, sortOrder: section.sortOrder)
        }
        return Output(
            courseCode: course.code, courseKey: course.urlKey, courseTerm: course.term?.displayName,
            sections: ordered)
    }
}

// MARK: - Shared

/// Resolves a course section by id and authorizes the acting account for a
/// *write* to its course (archived block).  Shared by rename_course_section /
/// delete_course_section — both mutate the section, so the write gate is the
/// correct floor (#417 Slice D-MCP).
func resolveCourseSectionForEdit(
    sectionID raw: String, context: ToolContext, atLeast minimum: CourseRole
) async throws -> APICourseSection {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let uuid = UUID(uuidString: trimmed) else {
        throw MCPToolError.invalidArguments(detail: "courseSectionID \"\(trimmed)\" is not a valid id.")
    }
    guard let section = try await APICourseSection.find(uuid, on: context.db) else {
        throw MCPToolError.invalidArguments(detail: "No course section with id \"\(trimmed)\".")
    }
    // Course-section structure is instructor-level (#417), matching the web.
    try await context.authorizeCourseWriteAccess(section.courseID, atLeast: minimum)
    return section
}

/// The tool error for a refused course section.
func mcpToolError(_ error: CourseSectionError) -> MCPToolError {
    .invalidArguments(detail: error.description)
}

// `currentManifestGradingMode` / `setManifestGradingMode` /
// `setManifestGraderOnly` moved to Services/ManifestFieldEdits.swift (#1121):
// they are cross-surface utilities (also used by AuthorScriptTool and
// SetGradingModeTool), not course-section concerns.
