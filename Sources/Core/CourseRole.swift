// Core/CourseRole.swift
//
// A user's role *within a single course*, carried on the enrollment join row
// (`course_enrollments.role`).
//
// Distinct from the deployment-global `UserRole` (student/instructor/admin/mcp)
// stored on the user: that one governs deployment administration, while
// `CourseRole` governs participation in one specific course. Modelling role
// per-enrollment is what lets a single account be an instructor in one course
// and a student in another. See docs/multi-course-roles.md.
//
// Two rungs ship initially. The type is `String`-backed and deliberately open
// to a future `ta` rung between `student` and `instructor` without a schema
// change — the column is a string; only the vocabulary grows.

public enum CourseRole: String, Codable, Sendable, Comparable {
    /// Submits to the course's assignments and views their own results.
    case student
    /// Authors and manages the course's assignments, suites, and content.
    case instructor

    /// Privilege rank for `atLeast`-style comparisons (higher = more
    /// privilege). The gap leaves room to slot a future `ta` rung between
    /// `student` and `instructor` without renumbering, so an
    /// `enrollment.role >= .instructor` check keeps reading naturally.
    private var rank: Int {
        switch self {
        case .student: return 0
        case .instructor: return 20
        }
    }

    public static func < (lhs: CourseRole, rhs: CourseRole) -> Bool {
        lhs.rank < rhs.rank
    }
}
