// APIServer/Models/APIBrightSpaceSyncLog.swift
//
// Append-only audit trail for BrightSpace grade pushes.  One row is written
// per meaningful sync event — a successful push, a failed push, or a student
// skipped because they have no resolvable BrightSpace account.  Routine
// no-ops (assignment with no grade item, course with no org unit) are NOT
// logged, so the log stays signal, not noise.
//
// Identity fields (username, assignmentTitle) are snapshotted rather than
// FK-joined so the log stays readable after a course/assignment/user is
// deleted — an audit trail should survive the records it describes.

import Fluent
import Vapor

final class APIBrightSpaceSyncLog: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: only mutated within a request/DB context before save.
    static let schema = "brightspace_sync_log"

    /// Terminal states recorded in the `status` column.
    enum Status: String {
        case success
        case error
        case skipped
    }

    @ID(key: .id)
    var id: UUID?

    @OptionalField(key: "course_id")
    var courseID: UUID?

    @Field(key: "test_setup_id")
    var testSetupID: String

    @Field(key: "assignment_title")
    var assignmentTitle: String

    @OptionalField(key: "user_id")
    var userID: UUID?

    @Field(key: "username")
    var username: String

    @OptionalField(key: "org_unit_id")
    var orgUnitID: String?

    @OptionalField(key: "grade_object_id")
    var gradeObjectID: String?

    @OptionalField(key: "points")
    var points: Double?

    /// One of `Status` raw values: "success" | "error" | "skipped".
    @Field(key: "status")
    var status: String

    @OptionalField(key: "detail")
    var detail: String?

    @Timestamp(key: "attempted_at", on: .create)
    var attemptedAt: Date?

    init() {}

    init(
        courseID: UUID?,
        testSetupID: String,
        assignmentTitle: String,
        userID: UUID?,
        username: String,
        orgUnitID: String?,
        gradeObjectID: String?,
        points: Double?,
        status: Status,
        detail: String?
    ) {
        self.courseID = courseID
        self.testSetupID = testSetupID
        self.assignmentTitle = assignmentTitle
        self.userID = userID
        self.username = username
        self.orgUnitID = orgUnitID
        self.gradeObjectID = gradeObjectID
        self.points = points
        self.status = status.rawValue
        self.detail = detail
    }
}
