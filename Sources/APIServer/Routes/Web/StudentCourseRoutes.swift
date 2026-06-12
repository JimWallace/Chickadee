// APIServer/Routes/Web/StudentCourseRoutes.swift
//
// Instructor-facing per-course, per-student submission views.  Lives
// outside the `/instructor` prefix so the URL carries the course code —
// the literal `students` second segment routes ahead of the vanity
// catch-all `/:courseCode/:assignmentSlug`.
//
// Extracted from `AssignmentRoutes` in v0.4.177 — Phase 2 of the
// audit-driven refactor.  No behaviour change.  The handlers themselves
// live in `AssignmentRoutes+StudentCourse.swift`, now extending this
// struct.

import Core
import Fluent
import Foundation
import Vapor

struct StudentCourseRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":courseCode", "students", ":urlToken", "submissions", use: courseStudentSubmissionsPage)
        routes.get(
            ":courseCode", "students", ":urlToken", "assignments", ":assignmentID", "history",
            use: studentAssignmentHistoryPage
        )
        routes.post(
            ":courseCode", "students", ":urlToken", "assignments", ":assignmentID", "retest",
            use: retestStudentAssignment
        )
        routes.post(
            ":courseCode", "students", ":urlToken", "assignments", ":assignmentID", "reset-notebook",
            use: resetStudentAssignmentNotebook
        )
        routes.post(
            ":courseCode", "students", ":urlToken", "assignments", ":assignmentID", "extension",
            use: saveStudentAssignmentExtension
        )
        routes.post(
            ":courseCode", "students", ":urlToken", "assignments", ":assignmentID", "extension",
            "delete",
            use: deleteStudentAssignmentExtension
        )
        routes.post(
            ":courseCode", "students", ":urlToken", "assignments", ":assignmentID", "grade-override",
            use: saveStudentAssignmentGradeOverride
        )
        routes.post(
            ":courseCode", "students", ":urlToken", "assignments", ":assignmentID", "grade-override",
            "delete",
            use: deleteStudentAssignmentGradeOverride
        )
    }
}
