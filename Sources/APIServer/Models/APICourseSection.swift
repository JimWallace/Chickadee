// APIServer/Models/APICourseSection.swift
//
// A course section groups assignments under a named heading (e.g. "Labs", "Exams").
// A section names no type: a new item's type comes from the Overview's "+ Add"
// menu or the create page (docs/assignment-types.md). Grading follows the
// type, never the section: a section has no grading mode, and moving an
// assignment between sections changes neither its type nor its grading mode.
//
// The two columns that sections used to carry, `default_grading_mode` and
// `default_assignment_type`, are dropped (`DropSectionDefaultColumns`).
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

    /// Ordering among sections within the course (lower = shown first).
    @Field(key: "sort_order")
    var sortOrder: Int

    /// The course this section belongs to.
    @Field(key: "course_id")
    var courseID: UUID

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, name: String, sortOrder: Int, courseID: UUID) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.courseID = courseID
    }
}
