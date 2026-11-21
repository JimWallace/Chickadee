// APIServer/Services/UsageReport.swift
//
// The usage report `UsageStatisticsBuilder` assembles for a set of academic
// terms: how many courses, people, assignments and submissions Chickadee
// carried. It feeds the admin MCP tool `get_usage_summary`, which an admin
// uses for annual reporting (an APR, a grant report).
//
// PII boundary: every field is a count, a course label (code, key, term) or a
// fixed vocabulary key (an assignment type, a language, a submission status).
// No user identifier, name or grade is part of any type here. A per-course row
// holds back its student counts when the course has fewer students than
// `UsageReport.smallCourseThreshold`, so a count cannot point at one student.

import Core
import Foundation

/// One counted key of a fixed vocabulary, e.g. `{"key": "python", "count": 12}`.
struct UsageCount: Codable, Sendable, Equatable {
    let key: String
    let count: Int
}

/// Submission counts for a set of courses.
struct UsageSubmissionTotals: Codable, Sendable, Equatable {
    /// Student submissions (`kind == student`): the graded work of record.
    let student: Int
    /// Student submissions by status (complete, failed, pending, ...).
    let studentByStatus: [UsageCount]
    /// Student submissions by source: upload or github.
    let studentBySource: [UsageCount]
    /// Instructor validation runs (`kind == validation`), kept apart from
    /// student work.
    let validation: Int
    /// The median number of student submissions per active student, or nil
    /// when no student submitted.
    let medianPerActiveStudent: Double?
}

/// The headline numbers of a report, or of one term within it.
struct UsageTotals: Codable, Sendable, Equatable {
    /// Course offerings (one code in one term).
    let courses: Int
    /// Distinct course codes among those offerings.
    let distinctCourseCodes: Int
    /// Distinct people holding a student enrollment in any counted course.
    let enrolledStudents: Int
    /// Distinct students who made at least one student submission or opened
    /// at least one browser-graded lab in a counted course. Course staff are
    /// not counted, even when they submitted as a student would.
    let activeStudents: Int
    /// Distinct people holding an instructor enrollment.
    let instructors: Int
    /// Distinct people holding a TA enrollment.
    let teachingAssistants: Int
    /// Assignments in the counted courses.
    let assignments: Int
    /// Assignments by declared type (assignment, lab, classActivity).
    let assignmentsByType: [UsageCount]
    /// Assignments by language (python, r, cpp, ..., or "none").
    let assignmentsByLanguage: [UsageCount]
    /// Ungraded course content items (links, notebooks, slides, ...).
    let contentItems: Int
    /// Submission counts.
    let submissions: UsageSubmissionTotals
    /// Student lab openings (`assignment_participations` rows): browser-graded
    /// work that never becomes a submission.
    let labParticipations: Int
    /// AI-assisted feedback drafts released to students.
    let aiFeedbackReleased: Int
    /// Class-activity tournaments run.
    let tournamentsRun: Int
}

/// Courses that used an optional integration.
struct UsageIntegrations: Codable, Sendable, Equatable {
    let brightSpaceCourses: Int
    let ltiCourses: Int
    let aiFeedbackCourses: Int
    let githubSubmissionCourses: Int
}

/// One term's slice of a report.
struct UsageTermBreakdown: Codable, Sendable, Equatable {
    /// "F26".
    let term: String
    /// "Fall 2026".
    let termName: String
    let totals: UsageTotals
}

/// One course offering's row in a report.
struct UsageCourseRow: Codable, Sendable, Equatable {
    let courseCode: String
    let courseKey: String
    let courseName: String
    /// "F26".
    let term: String
    /// True when the course records no term and the report placed it by the
    /// date it was created.
    let termInferred: Bool
    let archived: Bool
    /// Nil when the course is small (`smallCourse`).
    let enrolledStudents: Int?
    /// Nil when the course is small (`smallCourse`).
    let activeStudents: Int?
    /// True when the course has fewer students than
    /// `UsageReport.smallCourseThreshold`, so its student counts are held back.
    let smallCourse: Bool
    let instructors: Int
    let teachingAssistants: Int
    let assignments: Int
    let studentSubmissions: Int
    let labParticipations: Int
}

/// A usage report over a set of terms.
struct UsageReport: Codable, Sendable, Equatable {
    /// Per-course student counts below this are held back.
    static let smallCourseThreshold = 5

    let generatedAt: Date
    /// The terms counted, oldest first, as short labels ("W26").
    let terms: [String]
    let totals: UsageTotals
    let integrations: UsageIntegrations
    /// One entry per requested term, oldest first, including terms with no
    /// courses.
    let byTerm: [UsageTermBreakdown]
    /// One row per counted course, by term then code. Nil unless requested.
    let perCourse: [UsageCourseRow]?
    /// How to read the numbers: what is and is not counted.
    let notes: [String]
}
