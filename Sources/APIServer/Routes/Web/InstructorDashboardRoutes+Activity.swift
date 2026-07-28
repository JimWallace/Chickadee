// APIServer/Routes/Web/InstructorDashboardRoutes+Activity.swift
//
// GET /instructor/activity — the merged course activity timeline (#421).
//
// Visible to all course staff, not just the lead instructor. The `/instructor`
// group is already gated by `ActiveCourseStaffMiddleware` (TA+ in the ACTIVE
// course), which is exactly the audience and scope this page wants: a TA sees
// the course they are staff on, and nothing else. Transparency is the right
// default here — a shared record of who changed what beats a surveillance tool
// only the lead can read.
//
// Read-only, and scoped to the active course by construction: every query
// filters on the resolved course id, so there is no way to page into another
// course's history from this route.

import Fluent
import Foundation
import Vapor

extension InstructorDashboardRoutes {

    @Sendable
    func activityPage(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        let userContext = CurrentUserContext(
            user: user,
            activeCourse: courseState.active,
            enrolledCourses: courseState.all
        )

        struct ActivityQuery: Content {
            var actor: String?
        }
        let filter = (try? req.query.decode(ActivityQuery.self)) ?? ActivityQuery()
        let trimmedActor = filter.actor?.trimmingCharacters(in: .whitespaces) ?? ""
        let actorFilter = trimmedActor.isEmpty ? nil : trimmedActor

        guard let courseID = courseState.activeCourseUUID else {
            // No active course: render the empty state rather than 404ing, so
            // the tab behaves like the other instructor tabs.
            return try await req.view.render(
                "instructor-activity",
                InstructorActivityContext(
                    currentUser: userContext,
                    activeInstructorTab: "activity",
                    rows: [],
                    hasRows: false,
                    hasActiveCourse: false,
                    filterActor: trimmedActor,
                    filtered: actorFilter != nil))
        }

        let rows = try await CourseActivityService.timeline(
            courseID: courseID, actorFilter: actorFilter, on: req.db)

        return try await req.view.render(
            "instructor-activity",
            InstructorActivityContext(
                currentUser: userContext,
                activeInstructorTab: "activity",
                rows: rows,
                hasRows: !rows.isEmpty,
                hasActiveCourse: true,
                filterActor: trimmedActor,
                filtered: actorFilter != nil))
    }
}

/// Activity tab (`GET /instructor/activity`): the merged content-edit +
/// course-event timeline for the active course.
struct InstructorActivityContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeInstructorTab: String
    let rows: [CourseActivityRow]
    /// Explicit flag — Leaf's `array.isEmpty` is unreliable in this codebase.
    let hasRows: Bool
    let hasActiveCourse: Bool
    let filterActor: String
    let filtered: Bool
}
