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

        let r = routes.grouped("instructor")
        r.get("enroll-csv", use: enrollCSVForm)
        r.post("sections", use: createSection)
        r.post("sections", "reorder", use: reorderSections)
        r.post("sections", ":sectionID", "rename", use: renameSection)
        r.post("sections", ":sectionID", "delete", use: deleteSection)
        r.post(":assignmentID", "section", use: moveToSection)
    }
}
