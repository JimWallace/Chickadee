// APIServer/Routes/Web/ActivityRequest.swift
//
// The gate of a class activity's page (#2720): the setup in the path, its
// activity, the kind the page serves, and then the staff or enrollment
// check. The leaderboard, the class composite snapshot and the projector
// arena start here, so they read staff the same way. The group-session
// routes do not: they authorize the caller before they look at the
// activity (`requireGroupSession`).

import Core
import Fluent
import Vapor

struct ActivityRequest {
    let user: APIUser
    let setup: APITestSetup
    let activity: ClassActivity
    /// Course staff (TA and up) or an admin.
    let isStaff: Bool

    /// Who may reach the page.
    enum Audience {
        /// Course staff only. Anyone else gets the same 404 as a missing
        /// activity, so the page tells no one else that it exists.
        case staff
        /// Course staff, and anyone enrolled in the course. Someone who is
        /// not enrolled is refused.
        case course
    }

    /// The activity of the `testSetupID` path parameter, after the gate.
    /// A missing setup, an activity that `matches` refuses, and (for
    /// `.staff`) a viewer who is not staff are each a 404 that names
    /// `resource`. The setup and the activity are checked before the viewer,
    /// so the order of the answers is the same for each page.
    static func resolve(
        _ req: Request, resource: String, audience: Audience,
        matching matches: (ClassActivity) -> Bool = { _ in true }
    ) async throws -> ActivityRequest {
        let user = try req.auth.require(APIUser.self)
        guard let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db),
            let activity = setup.decodedManifest()?.activity, matches(activity)
        else { throw AppError.notFound(resource: resource) }

        let isStaff = try await req.cachedIsCourseStaff(user, inCourse: setup.courseID)
        if !isStaff {
            switch audience {
            case .staff:
                throw AppError.notFound(resource: resource)
            case .course:
                try await req.cachedRequireCourseEnrollment(caller: user, courseID: setup.courseID)
            }
        }
        return ActivityRequest(user: user, setup: setup, activity: activity, isStaff: isStaff)
    }
}
