// APIServer/LTI/LTIScore.swift
//
// The body of an AGS score POST. A score with no `scoreGiven` and
// `gradingProgress` = NotReady clears the student's grade on the LMS.

import Foundation

struct LTIScore: Codable, Equatable, Sendable {
    let userId: String
    let scoreGiven: Double?
    let scoreMaximum: Double?
    let activityProgress: String
    let gradingProgress: String
    /// ISO 8601 with fractional seconds. A platform ignores a score whose
    /// timestamp is not later than the last one it took for the student.
    let timestamp: String

    static func graded(userID: String, points: Double, maximum: Double, at date: Date) -> LTIScore {
        LTIScore(
            userId: userID, scoreGiven: points, scoreMaximum: maximum,
            activityProgress: "Completed", gradingProgress: "FullyGraded",
            timestamp: formatted(date))
    }

    static func cleared(userID: String, at date: Date) -> LTIScore {
        LTIScore(
            userId: userID, scoreGiven: nil, scoreMaximum: nil,
            activityProgress: "Initialized", gradingProgress: "NotReady",
            timestamp: formatted(date))
    }

    private static func formatted(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
    }
}
