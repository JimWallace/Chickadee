// APIServer/Models/APICourseSection.swift
//
// A course section groups assignments under a named heading (e.g. "Labs", "Exams").
// Each section has a default grading mode that pre-populates the creation form for
// new items added to that section.
//
// Assignments reference their section via a nullable section_id FK (SET NULL on delete),
// so deleting a section drops its assignments into the "ungrouped" bucket — no data loss.

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

    /// Default grading mode for new items created in this section.
    /// Values: "browser" | "worker"
    @Field(key: "default_grading_mode")
    var defaultGradingMode: String

    /// Ordering among sections within the course (lower = shown first).
    @Field(key: "sort_order")
    var sortOrder: Int

    /// The course this section belongs to.
    @Field(key: "course_id")
    var courseID: UUID

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, name: String, defaultGradingMode: String = "worker",
         sortOrder: Int, courseID: UUID) {
        self.id                 = id
        self.name               = name
        self.defaultGradingMode = defaultGradingMode
        self.sortOrder          = sortOrder
        self.courseID           = courseID
    }
}
