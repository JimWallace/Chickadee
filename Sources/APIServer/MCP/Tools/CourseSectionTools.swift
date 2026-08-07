// APIServer/MCP/Tools/CourseSectionTools.swift
//
// Tools for *course* sections — the named groups that organize an assignment
// list (e.g. "Labs", "Assignments", "Exams"), distinct from the test-suite
// sections inside a single assignment (create_suite_section / move_suite_item).  A
// course section (`APICourseSection`) has a name, a sort order, and a default
// grading mode; an assignment belongs to at most one via its nullable
// `sectionID`.  content:read for the listing, content:write for the rest.
//
// These mirror the web instructor dashboard handlers
// (`CourseAdminRoutes+Sections.swift`): create_course_section ~ createSection,
// set_assignment_course_section ~ moveToSection (including the grading-mode sync when
// moving into a named section).  This is assignment-organization metadata, not
// student/enrollment data.

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
            let defaultGradingMode: String
            let sortOrder: Int
        }
        let courseCode: String
        let sections: [Section]
    }

    static let name = "list_course_sections"
    static let description =
        "List the course sections (assignment groups like \"Labs\" or \"Assignments\") for a course, "
        + "identified by course code, in display order. Returns each section's id (use it as "
        + "set_assignment_course_section's courseSectionID), name, default grading mode (browser/worker), and "
        + "sort order. These are course-level groups for organizing the assignment list — not the "
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
            "sections": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "sectionID": MCPSchema.string,
                        "name": MCPSchema.string,
                        "defaultGradingMode": MCPSchema.string,
                        "sortOrder": MCPSchema.integer,
                    ]),
                    "required": .array([
                        .string("sectionID"), .string("name"), .string("defaultGradingMode"),
                        .string("sortOrder"),
                    ]),
                ]),
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("sections")]),
    ])
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let courseID = try await resolveCourseID(code: input.courseCode, tool: Self.name, context: context)
        let sections = try await APICourseSection.query(on: context.db)
            .filter(\.$courseID == courseID)
            .sort(\.$sortOrder)
            .all()
        let rows = sections.compactMap { section -> Output.Section? in
            guard let id = section.id else { return nil }
            return Output.Section(
                sectionID: id.uuidString,
                name: section.name,
                defaultGradingMode: section.defaultGradingMode,
                sortOrder: section.sortOrder)
        }
        return Output(courseCode: input.courseCode, sections: rows)
    }
}

// MARK: - create_course_section

struct CreateCourseSectionTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
        let name: String
        /// "browser" or "worker"; defaults to "browser".
        let defaultGradingMode: String?
    }

    struct Output: Encodable, Sendable {
        let courseCode: String
        let sectionID: String
        let name: String
        let defaultGradingMode: String
        let sortOrder: Int
    }

    static let name = "create_course_section"
    static let description =
        "Create a new course section (an assignment group like \"Labs\") in a course, by course code. "
        + "Provide a name and optionally defaultGradingMode (\"browser\" or \"worker\", default "
        + "\"browser\") — the mode an assignment adopts when moved into this section. The new section "
        + "is appended after the existing ones. Returns its id for use with set_assignment_course_section."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.courseCode,
            "name": .object([
                "type": .string("string"),
                "description": .string("Display name for the new section (non-empty), e.g. \"Labs\"."),
            ]),
            "defaultGradingMode": .object([
                "type": .string("string"),
                "enum": .array([.string("browser"), .string("worker")]),
                "description": .string("Grading mode adopted by assignments moved here. Default \"browser\"."),
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("name")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.string,
            "sectionID": MCPSchema.string,
            "name": MCPSchema.string,
            "defaultGradingMode": MCPSchema.string,
            "sortOrder": MCPSchema.integer,
        ]),
        "required": .array([
            .string("courseCode"), .string("sectionID"), .string("name"),
            .string("defaultGradingMode"), .string("sortOrder"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw MCPToolError.invalidArguments(tool: Self.name, detail: "Section name must not be empty.")
        }
        let mode = input.defaultGradingMode ?? "browser"
        guard mode == "browser" || mode == "worker" else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "defaultGradingMode must be \"browser\" or \"worker\".")
        }
        let courseID = try await resolveCourseIDForWrite(code: input.courseCode, tool: Self.name, context: context)

        let maxOrder =
            try await APICourseSection.query(on: context.db)
            .filter(\.$courseID == courseID)
            .max(\.$sortOrder) ?? 0
        let section = APICourseSection(
            name: name, defaultGradingMode: mode, sortOrder: maxOrder + 1, courseID: courseID)
        try await section.save(on: context.db)

        return Output(
            courseCode: input.courseCode,
            sectionID: try section.requireID().uuidString,
            name: name,
            defaultGradingMode: mode,
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
        /// The assignment's grading mode after any section-driven sync.
        let gradingMode: String?
    }

    static let name = "set_assignment_course_section"
    static let description =
        "Place an assignment into a course section (assignment group like \"Labs\"), or ungroup it, by "
        + "assignment public ID. courseSectionID comes from list_course_sections; pass \"\" (or omit) "
        + "to ungroup. Moving into a named section makes the assignment adopt that section's default "
        + "grading mode (browser/worker) — matching the web instructor dashboard; ungrouping leaves "
        + "the grading mode unchanged. This is organizational metadata and does not re-run validation "
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
            publicID: input.assignmentPublicID, tool: Self.name, atLeast: .instructor)

        // Resolve + validate the target section against this assignment's course.
        // A non-empty id that doesn't resolve is rejected rather than silently
        // ungrouping, so a typo'd id surfaces as an error to the agent.
        let raw = input.courseSectionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSectionID: UUID?
        if let raw, !raw.isEmpty, raw.lowercased() != "none" {
            guard let uuid = UUID(uuidString: raw) else {
                throw MCPToolError.invalidArguments(
                    tool: Self.name, detail: "courseSectionID \"\(raw)\" is not a valid id.")
            }
            guard let section = try await APICourseSection.find(uuid, on: context.db),
                section.courseID == assignment.courseID
            else {
                throw MCPToolError.invalidArguments(
                    tool: Self.name,
                    detail: "No course section with id \"\(raw)\" in this assignment's course.")
            }
            resolvedSectionID = uuid
        } else {
            resolvedSectionID = nil
        }

        assignment.sectionID = resolvedSectionID
        // Append to the destination lane's shared (assignment + content) order so
        // the moved assignment doesn't collide with an existing sort_order
        // (mirrors the web moveToSection under the unified-interleave model).
        assignment.sortOrder = try await nextAssignmentSortOrder(
            courseID: assignment.courseID, sectionID: resolvedSectionID, db: context.db)
        try await assignment.save(on: context.db)

        // Moving into a named section adopts that section's default grading
        // mode (mirrors the web moveToSection); ungrouping leaves it unchanged.
        var sectionName: String?
        var gradingMode: String?
        if let sectionUUID = resolvedSectionID,
            let section = try await APICourseSection.find(sectionUUID, on: context.db)
        {
            sectionName = section.name
            if let setup = try await APITestSetup.find(assignment.testSetupID, on: context.db) {
                // An upload-only assignment keeps worker grading rather than
                // adopting a browser default (which would be refused — no
                // notebook page to grade in); the move itself still succeeds.
                if section.defaultGradingMode == GradingMode.browser.rawValue,
                    currentManifestSubmissionMode(setup.manifest)
                        == SubmissionMode.upload.rawValue
                {
                    gradingMode = currentManifestGradingMode(setup.manifest)
                } else {
                    gradingMode = try await setManifestGradingMode(
                        setup: setup, to: section.defaultGradingMode, on: context.db)
                }
            }
        } else if let setup = try await APITestSetup.find(assignment.testSetupID, on: context.db) {
            gradingMode = currentManifestGradingMode(setup.manifest)
        }

        return Output(
            assignmentPublicID: assignment.publicID,
            sectionID: resolvedSectionID?.uuidString ?? "",
            sectionName: sectionName,
            gradingMode: gradingMode)
    }

}

// MARK: - rename_course_section

struct RenameCourseSectionTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseSectionID: String
        /// New display name; omit to leave unchanged.
        let name: String?
        /// "browser" or "worker"; omit to leave unchanged.
        let defaultGradingMode: String?
    }

    struct Output: Encodable, Sendable {
        let sectionID: String
        let name: String
        let defaultGradingMode: String
        let sortOrder: Int
    }

    static let name = "rename_course_section"
    static let description =
        "Rename a course section (assignment group like \"Labs\") and/or change its default grading "
        + "mode, by course-section id (from list_course_sections). Provide name and/or "
        + "defaultGradingMode (\"browser\"/\"worker\") — at least one. The default grading mode applies "
        + "only to assignments moved into the section AFTERWARDS (via set_assignment_course_section); it does "
        + "not re-grade or change assignments already in it. This is a course section (assignment "
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
                "description": .string("New display name (non-empty); omit to leave unchanged."),
            ]),
            "defaultGradingMode": .object([
                "type": .string("string"),
                "enum": .array([.string("browser"), .string("worker")]),
                "description": .string("New default grading mode; omit to leave unchanged."),
            ]),
        ]),
        "required": .array([.string("courseSectionID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "sectionID": MCPSchema.string,
            "name": MCPSchema.string,
            "defaultGradingMode": MCPSchema.string,
            "sortOrder": MCPSchema.integer,
        ]),
        "required": .array([
            .string("sectionID"), .string("name"), .string("defaultGradingMode"), .string("sortOrder"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let newName = input.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newMode = input.defaultGradingMode?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard newName != nil || newMode != nil else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "Provide at least one of: name, defaultGradingMode.")
        }
        let section = try await resolveCourseSectionForEdit(
            sectionID: input.courseSectionID, tool: Self.name, context: context)
        if let newName {
            guard !newName.isEmpty else {
                throw MCPToolError.invalidArguments(tool: Self.name, detail: "name must not be empty.")
            }
            section.name = newName
        }
        if let newMode {
            guard newMode == "browser" || newMode == "worker" else {
                throw MCPToolError.invalidArguments(
                    tool: Self.name, detail: "defaultGradingMode must be \"browser\" or \"worker\".")
            }
            section.defaultGradingMode = newMode
        }
        try await section.save(on: context.db)
        return Output(
            sectionID: try section.requireID().uuidString,
            name: section.name,
            defaultGradingMode: section.defaultGradingMode,
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
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "courseSectionID \"\(raw)\" is not a valid id.")
        }
        // Unknown id is an idempotent no-op (removed=false) — and reports nothing
        // that distinguishes "doesn't exist" from "in a course you can't see".
        guard let section = try await APICourseSection.find(uuid, on: context.db) else {
            return Output(sectionID: raw, removed: false, ungroupedAssignmentCount: 0)
        }
        // Deleting a course section is instructor-level structure (#417); archived blocked too.
        try await context.authorizeCourseWriteAccess(
            section.courseID, tool: Self.name, atLeast: .instructor)
        let ungrouped = try await APIAssignment.query(on: context.db)
            .filter(\.$sectionID == uuid)
            .count()
        // FK SET NULL: assignments in this section have section_id → NULL.
        try await section.delete(on: context.db)
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
        "required": .array([.string("courseCode"), .string("sections")]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let courseID = try await resolveCourseIDForWrite(code: input.courseCode, tool: Self.name, context: context)
        let uuids = input.orderedSectionIDs.compactMap {
            UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard uuids.count == input.orderedSectionIDs.count else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "orderedSectionIDs contains an invalid section id.")
        }
        guard Set(uuids).count == uuids.count else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "orderedSectionIDs contains a duplicate section id.")
        }
        let sections = try await APICourseSection.query(on: context.db)
            .filter(\.$courseID == courseID)
            .all()
        let existing = Set(sections.compactMap { $0.id })
        guard existing == Set(uuids) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "orderedSectionIDs must list exactly the course's current section ids "
                    + "(a permutation of all \(existing.count)).")
        }
        let byID = Dictionary(
            uniqueKeysWithValues: sections.compactMap { section -> (UUID, APICourseSection)? in
                guard let id = section.id else { return nil }
                return (id, section)
            })
        var ordered: [Output.Section] = []
        for (index, uuid) in uuids.enumerated() {
            guard let section = byID[uuid] else { continue }
            section.sortOrder = index + 1
            try await section.save(on: context.db)
            ordered.append(
                Output.Section(sectionID: uuid.uuidString, name: section.name, sortOrder: section.sortOrder))
        }
        return Output(courseCode: input.courseCode, sections: ordered)
    }
}

// MARK: - Shared

/// Resolves a course section by id and authorizes the acting account for a
/// *write* to its course (archived block).  Shared by rename_course_section /
/// delete_course_section — both mutate the section, so the write gate is the
/// correct floor (#417 Slice D-MCP).
func resolveCourseSectionForEdit(
    sectionID raw: String, tool: String, context: ToolContext, atLeast minimum: CourseRole = .instructor
) async throws -> APICourseSection {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let uuid = UUID(uuidString: trimmed) else {
        throw MCPToolError.invalidArguments(tool: tool, detail: "courseSectionID \"\(trimmed)\" is not a valid id.")
    }
    guard let section = try await APICourseSection.find(uuid, on: context.db) else {
        throw MCPToolError.invalidArguments(tool: tool, detail: "No course section with id \"\(trimmed)\".")
    }
    // Course-section structure is instructor-level (#417), matching the web.
    try await context.authorizeCourseWriteAccess(section.courseID, tool: tool, atLeast: minimum)
    return section
}

// `currentManifestGradingMode` / `setManifestGradingMode` /
// `setManifestGraderOnly` moved to Helpers/ManifestFieldEdits.swift (#1121):
// they are cross-surface utilities (also used by AuthorScriptTool,
// SetGradingModeTool, and the web CourseAdminRoutes+Sections), not
// course-section concerns.

/// Resolves a course code to its id, enforcing that the acting account may act
/// on it (read access).  Shared by the course-section tools, including the READ
/// `list_course_sections` — so this must NOT carry the archived-write block.
func resolveCourseID(code: String, tool: String, context: ToolContext) async throws -> UUID {
    guard
        let course = try await APICourse.query(on: context.db)
            .filter(\.$code == code)
            .first()
    else {
        throw MCPToolError.invalidArguments(tool: tool, detail: "No course found with code \"\(code)\".")
    }
    let courseID = try course.requireID()
    try await context.authorizeCourseAccess(courseID, tool: tool)
    return courseID
}

/// Write variant of `resolveCourseID`: resolves the course by code and
/// authorizes a *write* to it (archived block).  Used by the course-section
/// WRITE tools (create_course_section, reorder_course_sections, and
/// reorder_assignments) so they can't mutate an archived course; the read
/// `list_course_sections` stays on `resolveCourseID` (#417 Slice D-MCP).
func resolveCourseIDForWrite(
    code: String, tool: String, context: ToolContext, atLeast minimum: CourseRole = .instructor
) async throws -> UUID {
    guard
        let course = try await APICourse.query(on: context.db)
            .filter(\.$code == code)
            .first()
    else {
        throw MCPToolError.invalidArguments(tool: tool, detail: "No course found with code \"\(code)\".")
    }
    let courseID = try course.requireID()
    // Course-level structure edits (sections, assignment ordering, new
    // assignments) are instructor-level (#417), matching the web.
    try await context.authorizeCourseWriteAccess(courseID, tool: tool, atLeast: minimum)
    return courseID
}
