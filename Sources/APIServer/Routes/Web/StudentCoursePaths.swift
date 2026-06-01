// APIServer/Routes/Web/StudentCoursePaths.swift
//
// One-stop builder for the `/:courseCode/students/:urlToken/...` URL
// family used by the instructor "per-student grouped submissions" view
// and the per-student-per-assignment drilldown.  Centralising the
// formatting keeps the route registration, the dashboard's inbound
// links, and the redirects after POSTs in agreement.
//
// `:urlToken` is the opaque 8-character `APIUser.urlToken` rather than
// the username (#556) so usernames don't leak into nginx access logs,
// browser history, or Referer headers.  Token values are URL-safe
// lowercase alphanumeric and do not need percent-encoding, but encoding
// is still applied so the helper works correctly if a future format
// change introduces characters that do.

import Foundation

enum StudentCoursePaths {
    /// Grouped submissions page — `/:courseCode/students/:urlToken/submissions`.
    static func submissions(courseCode: String, urlToken: String) -> String {
        "/\(encode(courseCode))/students/\(encode(urlToken))/submissions"
    }

    /// Per-assignment history drilldown for one student.
    static func assignmentHistory(
        courseCode: String,
        urlToken: String,
        assignmentID: String
    ) -> String {
        baseAssignmentPath(
            courseCode: courseCode,
            urlToken: urlToken,
            assignmentID: assignmentID
        ) + "/history"
    }

    /// POST target — retest every submission the student has on one assignment.
    static func retest(
        courseCode: String,
        urlToken: String,
        assignmentID: String
    ) -> String {
        baseAssignmentPath(
            courseCode: courseCode,
            urlToken: urlToken,
            assignmentID: assignmentID
        ) + "/retest"
    }

    /// POST target — reset the student's working-copy notebook to the starter.
    static func reset(
        courseCode: String,
        urlToken: String,
        assignmentID: String
    ) -> String {
        baseAssignmentPath(
            courseCode: courseCode,
            urlToken: urlToken,
            assignmentID: assignmentID
        ) + "/reset-notebook"
    }

    /// POST target — upsert an extension for one student × one assignment.
    static func extensionSave(
        courseCode: String,
        urlToken: String,
        assignmentID: String
    ) -> String {
        baseAssignmentPath(
            courseCode: courseCode,
            urlToken: urlToken,
            assignmentID: assignmentID
        ) + "/extension"
    }

    /// POST target — remove an existing extension.
    static func extensionDelete(
        courseCode: String,
        urlToken: String,
        assignmentID: String
    ) -> String {
        extensionSave(courseCode: courseCode, urlToken: urlToken, assignmentID: assignmentID)
            + "/delete"
    }

    private static func baseAssignmentPath(
        courseCode: String,
        urlToken: String,
        assignmentID: String
    ) -> String {
        "/\(encode(courseCode))/students/\(encode(urlToken))/assignments/\(encode(assignmentID))"
    }

    private static func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }
}

/// Shorthand wrapper kept lowercase to match call sites that reach for a
/// "build the URL" helper without remembering the type name.
func studentSubmissionsURL(courseCode: String, urlToken: String) -> String {
    StudentCoursePaths.submissions(courseCode: courseCode, urlToken: urlToken)
}
