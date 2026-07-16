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
// Three rungs ship. The type is `String`-backed, so the vocabulary can grow
// without a schema change — the column is a string; only the vocabulary grows.

public enum CourseRole: String, Codable, Sendable, Comparable {
    /// Submits to the course's assignments and views their own results.
    case student
    /// Teaching assistant: views all students' submissions, retests, and edits
    /// assignments/tests/content — everything an instructor authors — but
    /// cannot manage enrollment, deadlines, archival, or course staff.
    case ta
    /// Authors and manages the course's assignments, suites, and content, plus
    /// enrollment, deadlines, archival, and staff (everything a TA can do, more).
    case instructor

    /// Privilege rank for `atLeast`-style comparisons (higher = more
    /// privilege). `ta` sits between `student` and `instructor`, so
    /// `role >= .ta` admits TAs and instructors while `role >= .instructor`
    /// admits instructors only.
    private var rank: Int {
        switch self {
        case .student: return 0
        case .ta: return 10
        case .instructor: return 20
        }
    }

    public static func < (lhs: CourseRole, rhs: CourseRole) -> Bool {
        lhs.rank < rhs.rank
    }
}
