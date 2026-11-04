// APIServer/Services/CourseCodeNotURLSafeRule.swift
//
// The `courseCodeNotURLSafe` health rule: an active course whose code has a
// character that a link cannot carry (`CourseCodeSyntax`), such as "/" or "?".
// The links Chickadee writes encode the key (`VanityURLRoutes.vanityPath`), but
// a link typed by hand or pasted into an LMS from the bare code splits or ends
// at that character, so it is a 404. Every door refuses such a code for a new code
// (`courseCodeConflict`); this rule reports a course that held one before
// the rule shipped, until an admin renames it.

import Fluent
import Vapor

/// Decides the rule from the active courses.
func decideCourseCodeNotURLSafe(courses: [APICourse]) -> RuleEvaluation {
    let unsafe = courses.filter { !CourseCodeSyntax.isURLSafe($0.code) }
        .map { "\"\($0.code)\"" }
        .sorted()
    guard !unsafe.isEmpty else { return .ok }
    let list = unsafe.joined(separator: ", ")
    return RuleEvaluation(
        isFiring: true,
        summary:
            "Typed links do not reach \(unsafe.count == 1 ? "course" : "courses") \(list): "
            + "the code has a character a link cannot carry. Rename the course.",
        details: ["courses": list])
}

/// Reads the active courses and decides the rule.
func evaluateCourseCodeNotURLSafe(on application: Application) async throws -> RuleEvaluation {
    let active = try await APICourse.query(on: application.db)
        .filter(\.$isArchived == false)
        .all()
    return decideCourseCodeNotURLSafe(courses: active)
}
