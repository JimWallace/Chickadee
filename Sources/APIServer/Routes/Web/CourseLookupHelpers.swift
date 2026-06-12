// APIServer/Routes/Web/CourseLookupHelpers.swift
//
// Shared course-by-code resolution for routes that accept a course code in
// the URL path (vanity URLs, instructor student-history links).

import Fluent
import Vapor

/// Resolves a non-archived course by its code, case-insensitively.
///
/// Codes are matched case-insensitively so URLs work however the user types
/// them. Fluent has no case-insensitive comparison that is portable across
/// SQLite and Postgres, so this fetches the (small) active-course set and
/// compares in Swift — one place to change if that trade-off ever shifts.
func findActiveCourse(byCode code: String, on db: Database) async throws -> APICourse? {
    let lowered = code.lowercased()
    return try await APICourse.query(on: db)
        .filter(\.$isArchived == false)
        .all()
        .first(where: { $0.code.lowercased() == lowered })
}
