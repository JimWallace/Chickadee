// APIServer/Routes/Web/CourseAdminRoutes.swift
//
// Instructor-scoped course administration: course section CRUD (create,
// rename, delete, reorder, move-assignment) and roster management (CSV
// bulk enrollment, individual unenroll, pre-enrollment cancellation).
//
// Extracted from `AssignmentRoutes` in v0.4.177 — Phase 2 of the
// audit-driven refactor.  No behaviour change.  The handlers themselves
// live in `AssignmentRoutes+Sections.swift` and
// `AssignmentRoutes+Enrollment.swift`, now extending this struct.

import Core
import Fluent
import Foundation
import Vapor

struct CourseAdminRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // Course-scoped instructor actions (not under the /instructor prefix).
        routes.post("courses", ":courseID", "enrollment-mode", use: setCourseEnrollmentMode)
        routes.post("courses", ":courseID", "enroll-csv", use: instructorBulkEnrollCSV)
        routes.post("courses", ":courseID", "unenroll", ":userID", use: instructorUnenrollUser)
        routes.post("courses", ":courseID", "pre-unenroll", ":preEnrollmentID", use: instructorCancelPreEnrollment)
        // Manually materialize a pending pre-enrollment into a real user (debug
        // / grade-sync-testing escape valve).
        routes.post(
            "courses", ":courseID", "pre-enroll", ":preEnrollmentID", "register",
            use: instructorRegisterPreEnrollment)
        // Set a roster member's per-course role (Phase 4b).
        routes.post("courses", ":courseID", "role", ":userID", use: instructorSetEnrollmentRole)
        // Self-serve staff invite: add a co-instructor / TA by username or email (#417 Slice F).
        routes.post("courses", ":courseID", "staff", use: instructorInviteStaff)

        let r = routes.grouped("instructor")
        r.get("enroll-csv", use: enrollCSVForm)
        r.post("sections", use: createSection)
        r.post("sections", "reorder", use: reorderSections)
        r.post("sections", ":sectionID", "rename", use: renameSection)
        r.post("sections", ":sectionID", "delete", use: deleteSection)
        r.post(":assignmentID", "section", use: moveToSection)
        // Ungraded course content items (reference material) inside a section.
        // Create + edit accept multipart file uploads, so they carry an explicit
        // body-collection cap (a few files at the per-file limit plus fields).
        r.on(.POST, "content-items", body: .collect(maxSize: "60mb"), use: createContentItem)
        r.post("content-items", "reorder", use: reorderContentItems)
        r.on(.POST, "content-items", ":id", "edit", body: .collect(maxSize: "60mb"), use: updateContentItem)
        r.post("content-items", ":id", "delete", use: deleteContentItem)
        r.post("content-items", ":id", "section", use: moveContentItemToSection)
        r.post(
            "content-items", ":id", "attachments", ":attachmentID", "delete",
            use: removeContentAttachment)
    }
}
