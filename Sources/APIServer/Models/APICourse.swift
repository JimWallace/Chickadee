// APIServer/Models/APICourse.swift
//
// A course groups assignments, submissions, and students together.
// Users enroll in one or more courses. Assignments belong to a course.
//
// Admins manage courses (create, archive). Enrollment policy is set per course
// via CourseEnrollmentMode: open (self-enroll), auto (all users), or closed (admin-managed).

import Core
import Fluent
import Vapor

final class APICourse: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context.
    static let schema = "courses"

    @ID(key: .id)
    var id: UUID?

    /// Short code shown in the course tab, e.g. "CMSC131".
    @Field(key: "code")
    var code: String

    /// Full display name, e.g. "Introduction to Object-Oriented Programming".
    @Field(key: "name")
    var name: String

    /// Archived courses are hidden from all users and their data is preserved.
    @Field(key: "is_archived")
    var isArchived: Bool

    /// Enrollment policy stored as raw string in DB; use `enrollmentMode` for typed access.
    @Field(key: "enrollment_mode")
    var enrollmentModeRaw: String

    /// Typed accessor for `enrollmentModeRaw`. Defaults to `.open` if the stored value is unrecognised.
    var enrollmentMode: CourseEnrollmentMode {
        get { CourseEnrollmentMode(rawValue: enrollmentModeRaw) ?? .open }
        set { enrollmentModeRaw = newValue.rawValue }
    }

    /// D2L BrightSpace org unit ID for this course (enables grade sync when set).
    @OptionalField(key: "brightspace_org_unit_id")
    var brightspaceOrgUnitID: String?

    /// Human-readable D2L org-unit name, cached when an admin binds the
    /// course to its org unit (we look the ID up and store the name so the
    /// binding is verifiable at a glance). Nil = unbound or unverified.
    @OptionalField(key: "brightspace_org_unit_name")
    var brightspaceOrgUnitName: String?

    /// The instructor whose connected LEARN identity drives grade sync for this
    /// course (the "designated" identity; grades push as that account). Defaults
    /// to whoever first connects + claims the course; reassignable. Nil = fall
    /// back to the deployment-wide (admin/env) identity.
    @OptionalField(key: "brightspace_sync_user_id")
    var brightspaceSyncUserID: UUID?

    /// D2L group category ID whose groups represent the "sections" for this
    /// course (e.g. the numeric ID of the "Lab Sections" category). When set,
    /// the section-sync sweep maps each student's group membership to
    /// `APICourseEnrollment.brightspaceSection`. Nil = sync skipped.
    @OptionalField(key: "brightspace_section_category_id")
    var brightspaceSectionCategoryID: String?

    /// This course's own authoring-voice guide for MCP agents, set by its
    /// instructors on the instructor MCP panel. When present it REPLACES
    /// Chickadee's default guide for content authored in this course (the
    /// panel seeds the editor with the default, so a course's guide starts as
    /// an edited copy of it). Nil = the course inherits the default, which is
    /// also what the panel stores when the text is reset, emptied, or left
    /// matching the default verbatim. Resolved via `courseAuthoringVoice`.
    @OptionalField(key: "mcp_instructions")
    var mcpInstructions: String?

    /// When this course was archived. Set by `toggleCourseArchive` when a
    /// course is archived (and cleared when un-archived). Archiving is
    /// Chickadee's "end of term" signal, so this is the anchor for the
    /// submission-retention clock — see `SubmissionRetentionService`. Nil
    /// while the course is active.
    @OptionalField(key: "archived_at")
    var archivedAt: Date?

    /// Slip-day policy columns (#1228). All three nullable so pre-existing
    /// courses read as "never configured"; resolve through the typed
    /// `slipDayPolicy` accessor, never these raw columns.
    @OptionalField(key: "slip_days_enabled")
    var slipDaysEnabled: Bool?

    @OptionalField(key: "slip_days_per_student")
    var slipDaysPerStudent: Int?

    @OptionalField(key: "slip_day_extension_hours")
    var slipDayExtensionHours: Int?

    /// Whether release output waits out the slip-day claim window (nil =
    /// yes, the default). See `SlipDayPolicy.releaseRevealHold`.
    @OptionalField(key: "slip_day_release_reveal_hold")
    var slipDayReleaseRevealHold: Bool?

    /// The LTI platform this course is bound to (docs/lti-1-3.md "Courses").
    /// Nil = not bound; set together with `ltiContextID`.
    @OptionalField(key: "lti_platform_id")
    var ltiPlatformID: UUID?

    /// The platform's `context.id` for the bound LMS course.
    @OptionalField(key: "lti_context_id")
    var ltiContextID: String?

    /// The AGS line-items URL of the bound LMS course, from the most recent
    /// launch that carried one (docs/lti-1-3.md "Grades through AGS").
    @OptionalField(key: "lti_line_items_url")
    var ltiLineItemsURL: String?

    /// True when an instructor chose AGS as this course's grade transport.
    /// Nil or false = Valence, the default. The two are never both active.
    @OptionalField(key: "lti_grades_enabled")
    var ltiGradesEnabled: Bool?

    /// The NRPS membership URL of the bound LMS course, from the most recent
    /// launch that carried one (docs/lti-1-3.md "Roster through NRPS").
    @OptionalField(key: "lti_memberships_url")
    var ltiMembershipsURL: String?

    /// True when grades for this course go to the LMS through AGS, and so
    /// never through the Valence sync.
    var usesLTIGrades: Bool {
        ltiGradesEnabled == true && ltiPlatformID != nil
    }

    /// The four-digit year of this offering (docs/course-terms.md). Nil on a
    /// course created before terms existed; resolve through `term`.
    @OptionalField(key: "term_year")
    var termYear: Int?

    /// The Waterloo term of this offering, as a `TermSeason` raw value.
    /// Resolve through `term`, never this raw column.
    @OptionalField(key: "term_season")
    var termSeasonRaw: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Children(for: \.$course)
    var enrollments: [APICourseEnrollment]

    init() {}

    init(
        id: UUID? = nil, code: String, name: String,
        isArchived: Bool = false, enrollmentMode: CourseEnrollmentMode = .open,
        brightspaceOrgUnitID: String? = nil,
        brightspaceOrgUnitName: String? = nil,
        term: AcademicTerm? = nil
    ) {
        self.id = id
        self.code = code
        self.name = name
        self.isArchived = isArchived
        self.enrollmentModeRaw = enrollmentMode.rawValue
        self.brightspaceOrgUnitID = brightspaceOrgUnitID
        self.brightspaceOrgUnitName = brightspaceOrgUnitName
        self.termYear = term?.year
        self.termSeasonRaw = term?.season.rawValue
    }
}

// MARK: - Term

extension APICourse {
    /// The offering's year and term, or nil when none is recorded (or the
    /// stored pair is incomplete). Setting nil clears both columns.
    var term: AcademicTerm? {
        get { AcademicTerm.resolve(year: termYear, season: termSeasonRaw) }
        set {
            termYear = newValue?.year
            termSeasonRaw = newValue?.season.rawValue
        }
    }
    /// The course's segment in URLs (`/:courseCode/...`): the code alone
    /// for a course with no term, else "CS135-F26". Two active offerings may
    /// share a code (docs/course-terms.md), so a URL names the term to stay
    /// unambiguous. `findActiveCourse(byKey:viewer:on:)` resolves both forms.
    var urlKey: String { Self.urlKey(code: code, term: term) }

    /// The URL key a course with `code` and `term` has, before it exists.
    static func urlKey(code: String, term: AcademicTerm?) -> String {
        guard let term else { return code }
        return "\(code)-\(term.shortLabel)"
    }
}

// MARK: - Slip-day policy

extension APICourse {
    /// The course's effective slip-day policy: nil columns resolve to
    /// disabled with the 2 × 24 h defaults (`SlipDayPolicy.resolve`).
    var slipDayPolicy: SlipDayPolicy {
        SlipDayPolicy.resolve(
            enabled: slipDaysEnabled,
            daysPerStudent: slipDaysPerStudent,
            extensionHours: slipDayExtensionHours,
            releaseRevealHold: slipDayReleaseRevealHold
        )
    }
}
