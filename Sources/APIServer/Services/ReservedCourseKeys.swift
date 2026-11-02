// APIServer/Services/ReservedCourseKeys.swift
//
// The course URL keys that a fixed route already owns (#2666).
//
// A vanity URL is `/:courseCode/:assignmentSlug` (`VanityURLRoutes`), and the
// router prefers a constant segment to a parameter. So a fixed route whose
// first segment is a constant, with a second segment after it, takes every
// URL of a course whose key is that segment: a course coded "data" loses
// `/data/<slug>` to the Data page (`GET /data/:courseKey`), and one coded
// "submissions" loses it to `GET /submissions/:submissionID`.
//
// The set is read from the live route table, not written down, so a new
// fixed route reserves its first segment with no list to update. Course
// create, edit, clone and import refuse a course whose code or URL key is in
// the set. Keys are compared case-folded, the rule `coursesMatching` applies.

import Core
import Vapor

extension Routes {
    /// The case-folded first segment of every GET route with two or more
    /// segments whose first segment is a constant. The vanity routes are GET
    /// only, and the router matches per method, so a POST-only prefix
    /// shadows nothing.
    var reservedCourseKeys: Set<String> {
        Set(
            all.compactMap { route in
                guard route.method == .GET, route.path.count >= 2, case .constant(let first) = route.path[0]
                else { return nil }
                return first.lowercased()
            })
    }
}

/// True when a course with `code` and `term` would answer a URL that a fixed
/// route owns: its bare code (an old bookmark resolves by code) or its
/// `urlKey` is a reserved first segment.
func courseKeyIsReserved(code: String, term: AcademicTerm?, routes: Routes) -> Bool {
    let reserved = routes.reservedCourseKeys
    return reserved.contains(code.lowercased())
        || reserved.contains(APICourse.urlKey(code: code, term: term).lowercased())
}
