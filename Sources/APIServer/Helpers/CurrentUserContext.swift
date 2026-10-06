// APIServer/Helpers/CurrentUserContext.swift
//
// The authenticated user as a Leaf view context.

import Core
import Foundation

/// Encodable snapshot of the authenticated user, safe to embed in any Leaf context.
struct CurrentUserContext: Encodable {
    let username: String
    let preferredName: String?
    let displayName: String?
    let email: String?
    let role: String
    let isAdmin: Bool
    /// The course the user is currently viewing (nil if no course info was resolved).
    let activeCourse: CourseContext?
    /// All courses the user is enrolled in (empty if no course info was resolved).
    let enrolledCourses: [CourseContext]
    /// True when the user is enrolled in more than one course (tab strip should show).
    let showCourseTabs: Bool
    /// True when the user is *staff* (TA or instructor, or an admin) in the
    /// active course. The nav's Instructor tab keys off this; the finer
    /// per-action floor (`ta` vs `instructor`) is enforced server-side (#417
    /// Slice E). Renamed from `isInstructorInActiveCourse` in #1127 — the old
    /// name predated the TA rung and had come to mean "staff".
    let isStaffInActiveCourse: Bool
    /// Every enrolled course where the user is staff (role ≥ `.ta`), plus
    /// *all* enrolled courses for an admin (who instructs the whole
    /// deployment). Drives the nav's Instructor surface so staff always have
    /// a direct link into each course they teach, regardless of which course
    /// is currently active. Inherits the code-sorted order of
    /// `enrolledCourses`.
    let staffCourses: [CourseContext]
    /// True when `staffCourses` is non-empty — the user is staff in at least
    /// one enrolled course. The nav's Instructor entry shows whenever this is
    /// true, not only when the *active* course happens to be one they teach.
    let isStaffAnywhere: Bool
    /// True when the user is staff in more than one course, so the nav should
    /// render the per-course Instructor strip (mirrors `showCourseTabs`).
    let showStaffTabs: Bool
    /// The single course this user staffs, when there is exactly one — the
    /// nav renders one direct "Instructor" link for it instead of a strip.
    /// nil when they staff zero or many courses.
    let primaryStaffCourse: CourseContext?

    init(user: APIUser, activeCourse: CourseContext? = nil, enrolledCourses: [CourseContext] = []) {
        let normalizedPreferredName = user.preferredName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredName = (normalizedPreferredName?.isEmpty == false) ? normalizedPreferredName : nil
        let normalizedDisplayName = user.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (normalizedDisplayName?.isEmpty == false) ? normalizedDisplayName : nil
        let normalizedEmail = user.email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let email = (normalizedEmail?.isEmpty == false) ? normalizedEmail : nil

        self.username = user.username
        self.preferredName = preferredName
        self.displayName = displayName
        self.email = email
        self.role = user.role
        self.isAdmin = user.isAdmin
        self.activeCourse = activeCourse
        self.enrolledCourses = enrolledCourses
        self.showCourseTabs = enrolledCourses.count > 1
        // Staff (TA or instructor) in the active course see the Instructor
        // surface; the finer per-action floor is enforced server-side (#417
        // Slice E).
        self.isStaffInActiveCourse =
            activeCourse != nil && ((activeCourse?.role ?? .student) >= .ta || user.isAdmin)
        // An admin instructs the whole deployment, so every enrollment counts;
        // everyone else, every course where they are staff (TA or instructor).
        // Order follows `enrolledCourses` (code-sorted).
        let staffCourses =
            user.isAdmin ? enrolledCourses : enrolledCourses.filter { $0.role >= .ta }
        self.staffCourses = staffCourses
        self.isStaffAnywhere = !staffCourses.isEmpty
        self.showStaffTabs = staffCourses.count > 1
        self.primaryStaffCourse = staffCourses.count == 1 ? staffCourses[0] : nil
    }
}
