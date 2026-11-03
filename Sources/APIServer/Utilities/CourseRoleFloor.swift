// APIServer/Utilities/CourseRoleFloor.swift
//
// The course-role floor of each named operation, held once (#2772). A web
// route, its MCP twin and the view that offers its control read the same
// constant, so a floor change on one surface reaches the others. The
// dashboard uses `DashboardControls`, so the page does not offer a TA a
// control that the server refuses (#2743).
//
// An operation that is not named here states its floor as a literal at its
// call site. The reorder floor is `SortOrderRenumbering.roleFloor`.
// `CourseRoleFloorGuardTests` refuses a literal floor in a file that
// implements a named operation.

import Core

enum CourseRoleFloor {
    /// Create an assignment: the new-assignment form, its draft and save,
    /// quick publish of an unpublished setup, duplicate, and the MCP
    /// `create_assignment` and `clone_assignment` tools.
    static let createAssignment: CourseRole = .instructor
    /// Change an assignment's status, or delete an assignment or an
    /// unpublished setup.
    static let assignmentLifecycle: CourseRole = .instructor
    /// Create, rename or delete a course section, or move an assignment to
    /// another section, on the web and through MCP. Section reorder is
    /// `SortOrderRenumbering.roleFloor`.
    static let manageSections: CourseRole = .instructor
    /// Create, edit or delete a course content item, on the web and through
    /// MCP. Content item reorder is `SortOrderRenumbering.roleFloor`.
    static let manageContentItems: CourseRole = .ta
    /// Write the course dataset library, on the web and through MCP.
    static let manageCourseDatasets: CourseRole = .ta
    /// Change an assignment's Student Options: the lab concept, solution
    /// visibility, the passing threshold, the secret-reveal token and GitHub
    /// submission. The MCP twin is `set_assignment_concept`.
    static let studentOptions: CourseRole = .instructor
    /// Configure or run an assignment's class activity: the leaderboard, the
    /// opponent, the window, the composite and the tournament, on the web
    /// and through MCP (`set_activity`, `run_tournament`).
    static let classActivity: CourseRole = .instructor
    /// Bind a course or an assignment to BrightSpace and push its grades.
    /// The LEARN tab hides these controls from a viewer below this floor.
    static let brightSpaceBinding: CourseRole = .instructor
}
