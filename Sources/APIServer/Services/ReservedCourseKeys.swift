// APIServer/Services/ReservedCourseKeys.swift
//
// The course URL keys that the server's own routes take (#2666).
//
// A vanity link is `/:courseCode/:assignmentSlug` (`VanityURLRoutes`). Vapor's
// router tries a constant segment before a parameter at every step and never
// backtracks, whatever the registration order. So when a course's code or URL
// key equals the first segment of any fixed route ("data", "submissions",
// "login", "lab"), the router takes the fixed branch, and every vanity link of
// that course is a 404 or the wrong page. The length of the fixed route does
// not matter: `/login` alone sends `/login/hw1` to a dead end.
//
// The set is read from the registered routes, never written by hand, so a new
// fixed route reserves its first segment without anyone listing it.

import Core
import Vapor

/// The lowercased first segments of every route whose first segment is a
/// constant.
struct ReservedCourseKeys: Sendable, Equatable {
    let segments: Set<String>

    init(segments: Set<String>) {
        self.segments = Set(segments.map { $0.lowercased() })
    }

    init(routes: [Route]) {
        var segments: Set<String> = []
        for route in routes {
            if case .constant(let first) = route.path.first {
                segments.insert(first)
            }
        }
        self.init(segments: segments)
    }

    /// Reserves nothing: for a door that keeps a course's existing key.
    static let none = ReservedCourseKeys(segments: [])

    /// True when a course with `code` and `term` would lose its vanity links:
    /// its bare code or its URL key is a reserved segment. Case-insensitive,
    /// because `coursesMatching` resolves a key without regard to case, so a
    /// hand-typed `/data/hw1` for a course coded "DATA" reaches the fixed route.
    func reserves(code: String, term: AcademicTerm?) -> Bool {
        segments.contains(code.lowercased())
            || segments.contains(APICourse.urlKey(code: code, term: term).lowercased())
    }
}

extension Application {
    /// The keys the registered routes take. Read on use: the routes are fixed
    /// once the app boots, and the walk is cheap beside the course query that
    /// every caller makes next.
    var reservedCourseKeys: ReservedCourseKeys {
        ReservedCourseKeys(routes: routes.all)
    }
}
