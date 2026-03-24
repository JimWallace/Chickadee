// Core/CourseEnrollmentMode.swift
//
// Three-state enrollment policy per course.

public enum CourseEnrollmentMode: String, Codable, Sendable {
    /// Students see the course on /enroll and can self-enroll.
    case open
    /// Every authenticated user is enrolled automatically at login.
    case auto
    /// Enrollment is instructor/admin-managed only; students cannot self-enroll.
    case closed
}
