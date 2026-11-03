// APIServer/Services/CourseKeyShadowedRule.swift
//
// The `courseKeyShadowed` health rule: an active course whose code or URL key
// is the first segment of a fixed route (#2666). Every door that creates,
// renames or un-archives a course refuses such a code (`courseCodeConflict`);
// edit refuses only a change of code, so an existing course is not trapped. So
// this fires for the cases no door can see: a course that held the code before
// the refusal shipped, and a new fixed route that takes the code of a course
// that already exists. Either way the course's vanity links are 404s or the wrong
// page, and nothing else reports it.

import Fluent
import Vapor

/// Decides the rule from the active courses and the reserved keys.
func decideCourseKeyShadowed(courses: [APICourse], reserved: ReservedCourseKeys) -> RuleEvaluation {
    let shadowed = courses.filter { reserved.reserves(code: $0.code, term: $0.term) }
        .map(\.urlKey)
        .sorted()
    guard !shadowed.isEmpty else { return .ok }
    let list = shadowed.joined(separator: ", ")
    return RuleEvaluation(
        isFiring: true,
        summary:
            "Vanity links do not reach \(shadowed.count == 1 ? "course" : "courses") \(list): "
            + "the code is a page address on this server. Rename the course.",
        details: ["courses": list])
}

/// Reads the active courses and decides the rule.
func evaluateCourseKeyShadowed(on application: Application) async throws -> RuleEvaluation {
    let active = try await APICourse.query(on: application.db)
        .filter(\.$isArchived == false)
        .all()
    return decideCourseKeyShadowed(courses: active, reserved: application.reservedCourseKeys)
}
