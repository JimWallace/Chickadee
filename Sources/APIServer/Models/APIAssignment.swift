// APIServer/Models/APIAssignment.swift
//
// An assignment is a test setup that an instructor has published to the class.
// Students only see test setups that have a corresponding open assignment.
//
// Separating this from APITestSetup allows:
//   - Soft open/close without deleting the setup
//   - Due dates (isOpen flips to false automatically when due — future work)
//   - Per-student overrides later (another join table)

import Core
import Fluent
import Vapor

final class APIAssignment: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context.
    static let schema = "assignments"
    static let publicIDLength = 6

    @ID(key: .id)
    var id: UUID?

    /// Short public URL identifier (6-char base62 token).
    @Field(key: "public_id")
    var publicID: String

    /// Foreign reference to test_setups.id (string PK).
    @Field(key: "test_setup_id")
    var testSetupID: String

    /// Human-readable name shown in the student UI.
    @Field(key: "title")
    var title: String

    /// Stable, course-scoped vanity URL slug.
    @Field(key: "slug")
    var slug: String

    /// Optional deadline. nil = no deadline.
    @OptionalField(key: "due_at")
    var dueAt: Date?

    /// Optional automatic open date. nil = open as soon as published.
    /// When set and still in the future, students cannot access or submit
    /// even if `isOpen` is true. Once the time arrives, a `.closed`/`.preview`
    /// assignment is published by `openScheduledAssignment` — via the periodic
    /// deadline sweep, the dashboard load, and the submission gate (the latter
    /// two as lazy safety nets) — which consumes this field (sets it nil).
    @OptionalField(key: "starts_at")
    var startsAt: Date?

    /// Student-visibility / submission state, stored as the raw
    /// `AssignmentVisibility` string ("closed" | "preview" | "open"). Use the
    /// typed `visibility` accessor. Replaces the historical `is_open` boolean.
    @Field(key: "visibility")
    var visibilityRaw: String

    /// Typed accessor for `visibilityRaw`. Defaults to `.closed` (hidden from
    /// students) if the stored value is unrecognised — the safe direction.
    var visibility: AssignmentVisibility {
        get { AssignmentVisibility(rawValue: visibilityRaw) ?? .closed }
        set { visibilityRaw = newValue.rawValue }
    }

    /// Read-only derived convenience: true only in `.open`. Most student-facing
    /// checks are two-way ("is it open for students?"), and `.preview` is
    /// deliberately equivalent to `.closed` for students, so these keep working
    /// unchanged. The stored source of truth is `visibility`; this never widens
    /// it (it cannot represent `.preview`).
    var isOpen: Bool { visibility == .open }

    /// True when an instructor manually re-opened a past-due assignment.
    /// Nil/false means normal deadline auto-close behavior applies.
    @OptionalField(key: "deadline_override_active")
    var deadlineOverrideActive: Bool?

    /// Instructor-defined ordering for dashboard display (lower first).
    @OptionalField(key: "sort_order")
    var sortOrder: Int?

    /// Runner validation state for instructor-created assignments.
    /// Values: "pending" | "passed" | "failed"
    @OptionalField(key: "validation_status")
    var validationStatus: String?

    /// Submission ID for the runner validation run, if any.
    @OptionalField(key: "validation_submission_id")
    var validationSubmissionID: String?

    /// The section this assignment belongs to (nil = ungrouped).
    @OptionalField(key: "section_id")
    var sectionID: UUID?

    /// D2L BrightSpace grade item (grade object) ID for grade sync (instructor-entered).
    @OptionalField(key: "brightspace_grade_object_id")
    var brightspaceGradeObjectID: String?

    /// When true, this assignment is *explicitly* excluded from BrightSpace grade
    /// sync — distinct from "not yet mapped" (`brightspaceGradeObjectID == nil`),
    /// which only means the instructor hasn't wired a grade item yet. The sweep
    /// skips an excluded assignment without recording an error, and the mapping
    /// (if any) is preserved so re-enabling restores it. nil/false = not excluded.
    @OptionalField(key: "brightspace_sync_excluded")
    var brightspaceSyncExcluded: Bool?

    /// The course this assignment belongs to.
    @Field(key: "course_id")
    var courseID: UUID

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    static func generatePublicID(length: Int = APIAssignment.publicIDLength) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).compactMap { _ in alphabet.randomElement(using: &rng) })
    }

    init(
        id: UUID? = nil, publicID: String = APIAssignment.generatePublicID(), testSetupID: String, title: String,
        slug: String? = nil,
        dueAt: Date? = nil, startsAt: Date? = nil, visibility: AssignmentVisibility = .open,
        deadlineOverrideActive: Bool = false,
        sortOrder: Int? = nil,
        validationStatus: String? = nil,
        validationSubmissionID: String? = nil,
        sectionID: UUID? = nil,
        courseID: UUID
    ) {
        self.id = id
        self.publicID = publicID
        self.testSetupID = testSetupID
        self.title = title
        self.slug = slug ?? VanityURLRoutes.slugify(title)
        self.dueAt = dueAt
        self.startsAt = startsAt
        self.visibilityRaw = visibility.rawValue
        self.deadlineOverrideActive = deadlineOverrideActive
        self.sortOrder = sortOrder
        self.validationStatus = validationStatus
        self.validationSubmissionID = validationSubmissionID
        self.sectionID = sectionID
        self.courseID = courseID
    }

    /// Back-compat convenience: construct with the legacy `isOpen` boolean
    /// (true ⇒ `.open`, false ⇒ `.closed`). `.preview` is only reachable via
    /// `AssignmentAuthoringService.setVisibility`, never at construction, so a
    /// boolean is sufficient here. `isOpen` is intentionally not defaulted so
    /// this never collides with the visibility-based initializer above.
    convenience init(
        id: UUID? = nil, publicID: String = APIAssignment.generatePublicID(), testSetupID: String,
        title: String, slug: String? = nil,
        dueAt: Date? = nil, startsAt: Date? = nil, isOpen: Bool,
        deadlineOverrideActive: Bool = false,
        sortOrder: Int? = nil,
        validationStatus: String? = nil,
        validationSubmissionID: String? = nil,
        sectionID: UUID? = nil,
        courseID: UUID
    ) {
        self.init(
            id: id, publicID: publicID, testSetupID: testSetupID, title: title, slug: slug,
            dueAt: dueAt, startsAt: startsAt, visibility: isOpen ? .open : .closed,
            deadlineOverrideActive: deadlineOverrideActive, sortOrder: sortOrder,
            validationStatus: validationStatus, validationSubmissionID: validationSubmissionID,
            sectionID: sectionID, courseID: courseID)
    }
}
