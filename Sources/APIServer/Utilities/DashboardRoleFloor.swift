// APIServer/Utilities/DashboardRoleFloor.swift
//
// The course-role floors of the instructor dashboard actions that a TA may
// not take. `ActiveCourseStaffMiddleware` lets a TA into `/instructor`, so
// each of these routes states its finer floor. The route handler and the
// dashboard view (`DashboardControls`) read the same constant, so the page
// does not offer a TA a control that the server refuses (#2743).

import Core

enum DashboardRoleFloor {
    /// Create an assignment: the new-assignment form, its draft and save,
    /// quick publish of an unpublished setup, and duplicate.
    static let createAssignment: CourseRole = .instructor
    /// Change an assignment's status, or delete an assignment or an
    /// unpublished setup.
    static let assignmentLifecycle: CourseRole = .instructor
    /// Create, rename or delete a course section, or move an assignment to
    /// another section. Section reorder is `SortOrderRenumbering.roleFloor`.
    static let manageSections: CourseRole = .instructor
}
