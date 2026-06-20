// APIServer/Routes/Web/InstructorDashboardRoutes+LearnCheck.swift
//
// GET /instructor/students/learn-check — reconciles the active course's
// Chickadee roster against the LEARN (D2L) classlist and returns the row IDs
// of students who are no longer registered on LEARN, so the instructor can
// remove them from the Students tab.  Advisory only: it flags rows; the actual
// removal stays the instructor's per-row manual action (the existing unenroll
// / pre-unenroll buttons).
//
// Dormant until BrightSpace credentials are configured (pending UWaterloo
// IST) — returns a clear `configured: false` / `courseLinked: false` payload
// in that case so the panel can explain why nothing was flagged.

import Core
import Fluent
import Foundation
import Vapor

extension InstructorDashboardRoutes {

    // MARK: - GET /instructor/students/learn-check

    @Sendable
    func studentsLearnCheck(req: Request) async throws -> LearnRosterCheckResult {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)

        guard let courseUUID = courseState.activeCourseUUID,
            let course = try await APICourse.find(courseUUID, on: req.db)
        else {
            return .unavailable("No active course selected.")
        }
        guard let client = try await req.application.brightSpaceClient(forCourse: course) else {
            return .unavailable(
                "BrightSpace isn't connected for this course yet.", configured: false)
        }
        guard let orgUnitID = course.brightspaceOrgUnitID, !orgUnitID.isEmpty else {
            return .unavailable(
                "This course isn't linked to a LEARN org unit (set it on the course page).",
                courseLinked: false)
        }

        let classlist: [BrightSpaceClasslistEntry]
        do {
            classlist = try await client.fetchClasslist(orgUnitID: orgUnitID, on: req.application)
        } catch {
            req.logger.warning("LEARN classlist fetch failed: \(error)")
            return .unavailable("Couldn't fetch the LEARN classlist: \(error).")
        }

        let learnIdentities = LearnRosterReconciler.identitySet(from: classlist)

        var notOnLearn: [String] = []
        var unverifiable: [String] = []
        var checkedCount = 0

        // Enrolled (logged-in) students: match on student ID, fall back to
        // username.  Only `student` rows can have "dropped"; instructor/admin
        // test accounts aren't roster members and must never be flagged.
        let enrollments = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == courseUUID)
            .all()
        let enrolledUserIDs = enrollments.map(\.userID)
        let enrolledUsers =
            enrolledUserIDs.isEmpty
            ? []
            : try await APIUser.query(on: req.db)
                .filter(\.$id ~~ enrolledUserIDs)
                .filter(\.$role == UserRole.student.rawValue)
                .all()
        for student in enrolledUsers {
            guard let id = student.id else { continue }
            checkedCount += 1
            let sid = student.studentID ?? ""
            switch LearnRosterReconciler.classify(
                candidateKeys: [sid, student.username],
                hasIdentityKey: !sid.isEmpty,
                learnIdentities: learnIdentities
            ) {
            case .onLearn: break
            case .notOnLearn: notOnLearn.append(id.uuidString)
            case .unverifiable: unverifiable.append(id.uuidString)
            }
        }

        // Pending pre-enrollments: only a username to match on.  These are the
        // "awaiting first login" rows the instructor most wants vetted.
        let pending = try await APIPreEnrollment.query(on: req.db)
            .filter(\.$course.$id == courseUUID)
            .all()
        for entry in pending {
            guard let id = entry.id else { continue }
            checkedCount += 1
            if LearnRosterReconciler.classify(
                candidateKeys: [entry.username],
                hasIdentityKey: true,
                learnIdentities: learnIdentities
            ) == .notOnLearn {
                notOnLearn.append(id.uuidString)
            }
        }

        var message =
            "Checked \(checkedCount) against \(classlist.count) on LEARN — "
            + "\(notOnLearn.count) not registered on LEARN"
        if !unverifiable.isEmpty {
            message += ", \(unverifiable.count) couldn't be matched (no student ID)"
        }
        message += "."

        return LearnRosterCheckResult(
            ok: true,
            message: message,
            configured: true,
            courseLinked: true,
            notOnLearn: notOnLearn,
            unverifiable: unverifiable,
            checkedCount: checkedCount,
            learnCount: classlist.count)
    }
}

/// JSON payload for the Students-tab "Check against LEARN" button.  `notOnLearn`
/// and `unverifiable` carry the same row IDs the roster rows use
/// (`EnrolledStudentRow.id` — a user UUID for enrolled students, a
/// pre-enrollment UUID for pending rows), so the client can flag matching rows.
struct LearnRosterCheckResult: Content {
    let ok: Bool
    let message: String
    let configured: Bool
    let courseLinked: Bool
    let notOnLearn: [String]
    let unverifiable: [String]
    let checkedCount: Int
    let learnCount: Int

    /// Builds a "couldn't run" result (not configured, no org unit, fetch
    /// failed) with empty flag lists and a human-readable reason.
    static func unavailable(
        _ message: String,
        configured: Bool = true,
        courseLinked: Bool = true
    ) -> LearnRosterCheckResult {
        LearnRosterCheckResult(
            ok: false,
            message: message,
            configured: configured,
            courseLinked: courseLinked,
            notOnLearn: [],
            unverifiable: [],
            checkedCount: 0,
            learnCount: 0)
    }
}
