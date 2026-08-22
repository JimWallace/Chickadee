// APIServer/Models/APICourseEnrollment.swift
//
// Join table: a user is enrolled in a course.
// Both students and instructors enroll via the same mechanism.
//
// Each enrollment carries a per-course `role` (CourseRole) — the foundation
// for course-scoped capability, i.e. instructor in one course and student in
// another (see docs/multi-course-roles.md). The `role` column is part of
// CreateCourseEnrollments (folded there by the second consolidation round;
// the historical migration seeded pre-existing rows behaviour-preservingly
// from each user's then-global role). The nav, access checks, and roster UI
// all read the per-course role.

import Core
import Fluent
import Vapor

final class APICourseEnrollment: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context.
    static let schema = "course_enrollments"

    @ID(key: .id)
    var id: UUID?

    /// The enrolled user. Stored directly as UUID (not via @Parent) because
    /// APIUser uses UUID as its PK and we don't need eager-loading here.
    @Field(key: "user_id")
    var userID: UUID

    /// The course being enrolled in.
    @Parent(key: "course_id")
    var course: APICourse

    @Timestamp(key: "enrolled_at", on: .create)
    var enrolledAt: Date?

    /// The user's role *within this course* (`CourseRole`, stored as its raw
    /// string).  Declared optional because the column originally shipped as a
    /// nullable ALTER (Fluent + SQLite can't add a NOT NULL column to an
    /// existing table post-hoc — the same constraint that keeps
    /// `APIUser.url_token` nullable).  Every row carries a value in practice:
    /// fresh enrollments get one from `init` (defaulting to `.student`) and
    /// the historical role migration backfilled pre-existing rows.  Read it
    /// through the typed `role` accessor below, never this raw column.
    @OptionalField(key: "role")
    var roleRaw: String?

    /// This student's pseudonym in this course — "Quiet Cedar".
    ///
    /// Per (user, course) rather than per user: it is what makes uniqueness
    /// enforceable at enrollment time, and it keeps a student unlinkable across
    /// two courses' leaderboards. Unique within a course by
    /// `idx_enrollments_course_handle`, which excludes NULL so rows can be
    /// created before a handle is assigned. Materialized lazily by
    /// `AvatarStore.ensureHandle`.
    @OptionalField(key: "avatar_handle")
    var avatarHandle: String?

    /// LEARN grade-sync readiness for this (student, course): whether the
    /// roster-readiness sweep has confirmed we can deliver this student's grade
    /// to the course's LEARN classlist. Stored as `LearnSyncReadiness.rawValue`;
    /// NULL (a pre-existing row never swept) reads as `.unconfirmed`. Read it
    /// through the typed `learnSyncReadiness` accessor, never this raw column.
    @OptionalField(key: "brightspace_sync_status")
    var brightspaceSyncStatusRaw: String?

    /// When the readiness sweep last classified this enrollment. Nil = never.
    @OptionalField(key: "brightspace_checked_at")
    var brightspaceCheckedAt: Date?

    /// Human-readable reason for a non-`confirmed` status (e.g. "not on the
    /// LEARN classlist" / "no student ID to match on"). Nil when confirmed.
    @OptionalField(key: "brightspace_sync_detail")
    var brightspaceSyncDetail: String?

    /// The LEARN group name this student belongs to in the course's configured
    /// section category (e.g. "Lab 3"). Populated by the periodic section-sync
    /// sweep. Nil until the sweep has run or the student isn't in any group.
    @OptionalField(key: "brightspace_section")
    var brightspaceSection: String?

    /// Per-student slip-day budget adjustment (#1228): staff hand this
    /// student extra days (positive) or claw them back (negative) without
    /// touching the course-wide policy. Nil reads as 0.
    @OptionalField(key: "slip_days_adjustment")
    var slipDaysAdjustment: Int?

    init() {}

    init(id: UUID? = nil, userID: UUID, courseID: UUID, role: CourseRole = .student) {
        self.id = id
        self.userID = userID
        self.$course.id = courseID
        self.roleRaw = role.rawValue
    }
}

// MARK: - LEARN grade-sync readiness

/// Whether Chickadee has verified it can deliver this student's grade to the
/// course's LEARN gradebook. A *signal* layer, independent of the grade-push
/// path — an `unreachable` student's grade still queues and is never lost; the
/// status just tells the instructor we can't deliver it yet.
enum LearnSyncReadiness: String, Codable, Sendable {
    /// Default on enroll — not yet checked against the LEARN classlist.
    case unconfirmed
    /// Matched to a LEARN classlist identity — we can push this student's grade.
    case confirmed
    /// Checked, but we can't deliver: not on the classlist, or no key to match.
    case unreachable
}

extension APICourseEnrollment {
    /// The enrollment's typed LEARN sync readiness. A missing / unrecognised
    /// stored value reads as `.unconfirmed` (a row the sweep hasn't reached).
    var learnSyncReadiness: LearnSyncReadiness {
        get { brightspaceSyncStatusRaw.flatMap(LearnSyncReadiness.init(rawValue:)) ?? .unconfirmed }
        set { brightspaceSyncStatusRaw = newValue.rawValue }
    }
}

// MARK: - Per-course role

extension APICourseEnrollment {
    /// The enrollment's typed per-course role.  Falls back to `.student` for a
    /// missing or unrecognised stored value — defensive, since every row is
    /// expected to carry a valid role (seeded at insert, backfilled
    /// historically).
    var role: CourseRole {
        get { roleRaw.flatMap(CourseRole.init(rawValue:)) ?? .student }
        set { roleRaw = newValue.rawValue }
    }
}
