// APIServer/Models/APICourseSection.swift
//
// A course section groups assignments under a named heading (e.g. "Labs", "Exams").
// A section may name a default assignment type, which the new-assignment page and
// MCP `create_assignment` take when the author names none
// (docs/assignment-types.md, phase 3). Grading follows the type, never the
// section: a section has no grading mode, and moving an assignment between
// sections changes neither its type nor its grading mode.
//
// The `default_grading_mode` column that sections used to carry stays in the
// table, with a database default, until a later release drops it, so the old
// color of a blue-green deploy can still read the table
// (`AddSectionDefaultAssignmentType`). Nothing here reads or writes it.
//
// Assignments reference their section via a nullable section_id FK (SET NULL on delete),
// so deleting a section drops its assignments into the "ungrouped" bucket — no data loss.

import Core
import Fluent
import Vapor

final class APICourseSection: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context.
    static let schema = "course_sections"

    @ID(key: .id)
    var id: UUID?

    /// Instructor-defined label shown in both the instructor dashboard and the student view.
    @Field(key: "name")
    var name: String

    /// The `AssignmentType` raw value a new assignment in this section
    /// declares when its author names none. Nil = no default. Use the typed
    /// `defaultAssignmentType` accessor.
    @OptionalField(key: "default_assignment_type")
    var defaultAssignmentTypeRaw: String?

    /// Typed accessor for `defaultAssignmentTypeRaw`. An unrecognised value
    /// reads as no default.
    var defaultAssignmentType: AssignmentType? {
        get { defaultAssignmentTypeRaw.flatMap(AssignmentType.init(rawValue:)) }
        set { defaultAssignmentTypeRaw = newValue?.rawValue }
    }

    /// Ordering among sections within the course (lower = shown first).
    @Field(key: "sort_order")
    var sortOrder: Int

    /// The course this section belongs to.
    @Field(key: "course_id")
    var courseID: UUID

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil, name: String, defaultAssignmentType: AssignmentType? = nil,
        sortOrder: Int, courseID: UUID
    ) {
        self.id = id
        self.name = name
        self.defaultAssignmentTypeRaw = defaultAssignmentType?.rawValue
        self.sortOrder = sortOrder
        self.courseID = courseID
    }
}
