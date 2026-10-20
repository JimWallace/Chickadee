// APIServer/Views/DashboardControls.swift
//
// Which instructor-only controls the assignments dashboard shows the viewer.
// Each flag reads the floor of the route that the control calls.

import Core

struct DashboardControls {
    let createAssignment: Bool
    let assignmentLifecycle: Bool
    let manageSections: Bool

    /// An admin bypasses every floor, as in `evaluateCourseWrite`.
    init(viewer: CurrentUserContext?) {
        func meets(_ floor: CourseRole) -> Bool {
            guard let viewer else { return false }
            return viewer.isAdmin || viewer.activeCourse.map { $0.role >= floor } == true
        }
        createAssignment = meets(DashboardRoleFloor.createAssignment)
        assignmentLifecycle = meets(DashboardRoleFloor.assignmentLifecycle)
        manageSections = meets(DashboardRoleFloor.manageSections)
    }
}
