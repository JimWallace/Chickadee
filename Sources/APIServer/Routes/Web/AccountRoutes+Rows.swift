// APIServer/Routes/Web/AccountRoutes+Rows.swift
//
// The course rows of the account page, built here so the handler is loads
// plus render (#1715). The shape `buildTestSetupRow` uses for the index.

import Core
import Foundation
import Vapor

/// One course on the account page: an enrolled one, with the student's
/// slip-day balance and class handle, or an open one the user may join.
struct AccountCourseRow: Encodable {
    let id: String
    let code: String
    let name: String
    /// "Fall 2026", or nil when the course records no term.
    let termLabel: String?
    let enrollmentMode: String
    /// "1 of 2 remaining" — the slip-day balance for a student enrollment in
    /// a course with the policy on; nil hides the line (#1228).
    let slipDaysText: String?
    /// This student's pseudonym in this course, "Hazy Cedar". nil hides the
    /// line — a course whose word lists are exhausted, which is a real state
    /// rather than an error: the avatar still shows.
    let handle: String?
    /// Whether the student can still choose a different handle, and the
    /// options if so.  nil wherever `handle` is nil.
    let handleChoice: AccountHandleChoice?
}

extension AccountRoutes {
    /// A row for a course the user is enrolled in.
    ///
    /// "N of M slip days left" only where it means something: the course has
    /// slip days on and this enrollment is a student (staff never hold a
    /// balance). The phrase carries its own noun so the row needs no "Slip
    /// days:" label beside it. `slipDaysUsed` is the count of unrefunded
    /// spends in this course.
    static func enrolledCourseRow(
        for enrollment: APICourseEnrollment, courseID: UUID, slipDaysUsed: Int,
        handle: String?, handleChoice: AccountHandleChoice?
    ) -> AccountCourseRow {
        let course = enrollment.course
        let policy = course.slipDayPolicy
        let slipDaysText: String?
        if policy.enabled, enrollment.role == .student {
            let total = policy.daysPerStudent + (enrollment.slipDaysAdjustment ?? 0)
            slipDaysText = "\(max(total - slipDaysUsed, 0)) of \(total) slip days left"
        } else {
            slipDaysText = nil
        }
        return AccountCourseRow(
            id: courseID.uuidString,
            code: course.code,
            name: course.name, termLabel: course.term?.displayName,
            enrollmentMode: course.enrollmentMode.rawValue,
            slipDaysText: slipDaysText,
            handle: handle,
            handleChoice: handleChoice)
    }

    /// A row for an open course the user is not enrolled in, or nil for a
    /// course the user is in already or cannot self-enroll in.
    static func availableCourseRow(_ course: APICourse, enrolledIDs: Set<UUID>) -> AccountCourseRow? {
        guard let id = course.id, !enrolledIDs.contains(id), course.enrollmentMode == .open else { return nil }
        return AccountCourseRow(
            id: id.uuidString, code: course.code, name: course.name, termLabel: course.term?.displayName,
            enrollmentMode: course.enrollmentMode.rawValue,
            slipDaysText: nil, handle: nil, handleChoice: nil)
    }
}
