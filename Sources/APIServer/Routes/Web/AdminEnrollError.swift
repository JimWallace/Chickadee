// APIServer/Routes/Web/AdminEnrollError.swift
//
// Why the admin user page refused an enrollment. The handler redirects with
// the raw value in `?error=`, and the page shows the fixed message for it, so
// no text from the query ever reaches the page.

enum AdminEnrollError: String {
    /// The course ID did not name a course, or the course is archived.
    case invalidCourse = "invalid_course"

    var message: String {
        switch self {
        case .invalidCourse: "That course does not exist or is archived."
        }
    }
}
