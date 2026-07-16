// APIServer/Routes/Web/InstructorDashboardRoutes+Cards.swift
//
// GET /instructor/metrics/cards — JSON sparkline series for the instructor
// dashboard's diagnostic cards, scoped to the caller's active course.  Polled
// by assignments.leaf the same way the admin dashboard polls
// /admin/metrics/cards; the client cycles 24h / 7d / 30d from one payload.

import Core
import Fluent
import Foundation
import Vapor

extension InstructorDashboardRoutes {

    // MARK: - GET /instructor/metrics/cards

    @Sendable
    func metricsCards(req: Request) async throws -> InstructorCardSeriesResponse {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)

        guard let activeCourseUUID = courseState.activeCourseUUID else {
            return InstructorCardSeriesResponse(generatedAt: Date(), windows: [])
        }

        let setups = try await loadCourseSetups(req: req, activeCourseUUID: activeCourseUUID)
        let setupIDs = setups.compactMap(\.id)

        // Students are `.student`-role enrollments now (#417 Slice G2).
        let studentIDs = try await studentUserIDsInCourse(activeCourseUUID, on: req.db)

        return try await req.application.diagnostics.instructorCardSeries(
            setupIDs: setupIDs, studentIDs: studentIDs, on: req.db)
    }
}
