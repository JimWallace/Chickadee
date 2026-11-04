// APIServer/Helpers/CourseEnrollmentService.swift
//
// The roster changes that the instructor roster (`CourseAdminRoutes`) and the
// admin pages (`AdminRoutes`) share: remove an enrollment, set a per-course
// role, and invite a staff member. Each handler checks its own access and
// picks its own redirect; the change itself, its guards and its audit entries
// live here once, so the doors cannot drift (#2770).
//
// The admin bypass is the `caller` parameter: `ensureNotLastInstructor` lets
// an admin remove or demote a course's last instructor, because an admin can
// always grant the role again.

import Core
import Fluent
import Foundation
import Vapor

enum CourseEnrollmentService {
    /// Removes `userID` from `courseID`, if enrolled, and records the
    /// removal. A non-admin `caller` cannot remove the last instructor.
    static func unenroll(
        userID: UUID, courseID: UUID, caller: APIUser, on req: Request
    ) async throws {
        if let enrollment = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == courseID)
            .filter(\.$userID == userID)
            .first()
        {
            if enrollment.role == .instructor {
                try await ensureNotLastInstructor(
                    caller: caller, courseID: courseID, removing: userID, db: req.db)
            }
            try await enrollment.delete(on: req.db)
        }

        await AuditLogger.record(
            action: .enrollmentRemoved,
            targetType: .enrollment,
            targetID: userID.uuidString,
            metadata: ["course_id": courseID.uuidString, "subject_user_id": userID.uuidString],
            on: req
        )
    }

    /// Sets the per-course role of `userID` in `courseID` and records it.
    /// Returns false when the user has no enrollment in the course; the
    /// caller reports that in its own error shape. A non-admin `caller`
    /// cannot demote the last instructor.
    static func setRole(
        _ newRole: CourseRole, userID: UUID, courseID: UUID, caller: APIUser, on req: Request
    ) async throws -> Bool {
        guard
            let enrollment = try await APICourseEnrollment.query(on: req.db)
                .filter(\.$course.$id == courseID)
                .filter(\.$userID == userID)
                .first()
        else {
            return false
        }
        if enrollment.role == .instructor, newRole != .instructor {
            try await ensureNotLastInstructor(
                caller: caller, courseID: courseID, removing: userID, db: req.db)
        }
        enrollment.role = newRole
        try await enrollment.save(on: req.db)

        await AuditLogger.record(
            action: .enrollmentRoleChanged,
            targetType: .enrollment,
            targetID: userID.uuidString,
            metadata: [
                "course_id": courseID.uuidString, "subject_user_id": userID.uuidString,
                "role": newRole.rawValue,
            ],
            on: req
        )
        return true
    }

    /// Enrolls the person that `identifier` names at the staff `role`, and
    /// records it. The placeholder rule is the deployment's
    /// (`staffPlaceholderAllowed`) on every door: under local sign-in only,
    /// nothing can adopt a placeholder, so an unknown username is refused
    /// with `StaffProvisioningError.unknownUser`. The caller checks that
    /// `role` is a staff role.
    static func inviteStaff(
        identifier: String, role: CourseRole, courseID: UUID, source: String, on req: Request
    ) async throws {
        let result = try await provisionStaffEnrollment(
            identifier: identifier, role: role, courseID: courseID,
            allowPlaceholder: req.application.staffPlaceholderAllowed, on: req.db)
        await recordStaffProvisioning(result, role: role, courseID: courseID, source: source, on: req)
    }
}
