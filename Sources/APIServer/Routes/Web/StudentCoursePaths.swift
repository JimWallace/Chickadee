// APIServer/Routes/Web/StudentCoursePaths.swift
//
// One-stop builder for the `/:courseCode/students/:username/...` URL family
// introduced for the instructor "per-student grouped submissions" view.
// Centralising the formatting keeps the route registration, the inbound
// links (instructor dashboard roster), and the redirects after POSTs in
// agreement.  All paths are URL-encoded so course codes / usernames with
// unusual characters don't break the links.

import Foundation

enum StudentCoursePaths {
    /// Grouped submissions page — `/:courseCode/students/:username/submissions`.
    static func submissions(courseCode: String, username: String) -> String {
        "/\(encode(courseCode))/students/\(encode(username))/submissions"
    }

    /// Per-assignment history drilldown for one student.
    static func assignmentHistory(
        courseCode: String,
        username: String,
        assignmentID: String
    ) -> String {
        "\(submissions(courseCode: courseCode, username: username))"
            .replacingOccurrences(of: "/submissions", with: "")
            + "/assignments/\(encode(assignmentID))/history"
    }

    /// POST target — retest every submission the student has on one assignment.
    static func retest(
        courseCode: String,
        username: String,
        assignmentID: String
    ) -> String {
        baseAssignmentPath(
            courseCode: courseCode,
            username: username,
            assignmentID: assignmentID
        ) + "/retest"
    }

    /// POST target — upsert an extension for one student × one assignment.
    static func extensionSave(
        courseCode: String,
        username: String,
        assignmentID: String
    ) -> String {
        baseAssignmentPath(
            courseCode: courseCode,
            username: username,
            assignmentID: assignmentID
        ) + "/extension"
    }

    /// POST target — remove an existing extension.
    static func extensionDelete(
        courseCode: String,
        username: String,
        assignmentID: String
    ) -> String {
        extensionSave(courseCode: courseCode, username: username, assignmentID: assignmentID)
            + "/delete"
    }

    private static func baseAssignmentPath(
        courseCode: String,
        username: String,
        assignmentID: String
    ) -> String {
        "/\(encode(courseCode))/students/\(encode(username))/assignments/\(encode(assignmentID))"
    }

    private static func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }
}

/// Shorthand wrapper kept lowercase to match call sites that reach for a
/// "build the URL" helper without remembering the type name.
func studentSubmissionsURL(courseCode: String, username: String) -> String {
    StudentCoursePaths.submissions(courseCode: courseCode, username: username)
}
