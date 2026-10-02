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

        // The person filter is a select of course staff, "Everyone" first. A
        // `?actor=` naming someone who is not on it (a former staff member, or
        // "system") still gets its own option so the select shows what is applied.
        var staffOptions: [ActivityStaffOption] = []

        guard let courseID = courseState.activeCourseUUID else {
            // No active course: render the empty state rather than 404ing, so
            // the tab behaves like the other instructor tabs.
            return try await req.view.render(
                "instructor-activity",
                InstructorActivityContext(
                    currentUser: userContext,
                    activeInstructorTab: "activity",
                    days: [],
                    staffOptions: [],
                    hasRows: false,
                    hasActiveCourse: false,
                    filterActor: trimmedActor,
                    filtered: actorFilter != nil))
        }

        let rows = try await CourseActivityService.timeline(
            courseID: courseID, actorFilter: actorFilter, on: req.db)
        staffOptions = try await Self.activityStaffOptions(
            courseID: courseID, selected: actorFilter, db: req.db)

        return try await req.view.render(
            "instructor-activity",
            InstructorActivityContext(
                currentUser: userContext,
                activeInstructorTab: "activity",
                days: ActivityDay.group(rows),
                staffOptions: staffOptions,
                hasRows: !rows.isEmpty,
                hasActiveCourse: true,
                filterActor: trimmedActor,
                filtered: actorFilter != nil))
    }
}

/// Activity tab (`GET /instructor/activity`): the merged content-edit +
/// course-event timeline for the active course.
private struct InstructorActivityContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeInstructorTab: String
    /// The rows grouped under Today / Yesterday / date headings.
    let days: [ActivityDay]
    /// The person select: "Everyone" first, then course staff by name.
    let staffOptions: [ActivityStaffOption]
    /// Explicit flag — Leaf's `array.isEmpty` is unreliable in this codebase.
    let hasRows: Bool
    let hasActiveCourse: Bool
    let filterActor: String
    let filtered: Bool
}

/// One entry in the Activity tab's person select.
private struct ActivityStaffOption: Encodable, Equatable {
    /// The `actor` query value; empty for "Everyone".
    let username: String
    let displayName: String
    let selected: Bool
}

extension InstructorDashboardRoutes {
    /// "Everyone", then the course's instructors and TAs by name. If `selected`
    /// names someone not in that list it is added, so the select never shows
    /// "Everyone" while a filter is applied.
    private static func activityStaffOptions(
        courseID: UUID, selected: String?, db: any Database
    ) async throws -> [ActivityStaffOption] {
        let enrollments = try await APICourseEnrollment.query(on: db)
            .filter(\.$course.$id == courseID)
            .all()
        let staffIDs = enrollments.filter { $0.role >= .ta }.map(\.userID)
        var users: [APIUser] = []
        if !staffIDs.isEmpty {
            users = try await APIUser.query(on: db)
                .filter(\.$id ~~ staffIDs)
                .filter(\.$role != UserRole.mcp.rawValue)
                .all()
        }
        users.sort {
            ($0.displayName ?? $0.username).localizedStandardCompare($1.displayName ?? $1.username)
                == .orderedAscending
        }
        var options = [ActivityStaffOption(username: "", displayName: "Everyone", selected: selected == nil)]
        options += users.map {
            ActivityStaffOption(
                username: $0.username, displayName: $0.displayName ?? $0.username,
                selected: selected == $0.username)
        }
        if let selected, !options.contains(where: { $0.username == selected }) {
            options.append(ActivityStaffOption(username: selected, displayName: selected, selected: true))
        }
        return options
    }
}
