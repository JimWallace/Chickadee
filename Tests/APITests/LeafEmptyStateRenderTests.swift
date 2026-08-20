// Tests/APITests/LeafEmptyStateRenderTests.swift
//
// Empty states must actually render when the collection behind them is empty.
//
// This pins a defect class that every other kind of coverage is blind to.
// LeafKit walks a keypath by requiring each intermediate to be a dictionary
// (`Dictionary+LeafData.swift`), so `rows.isEmpty` on an ARRAY resolves to nil
// rather than erroring — LeafKit has no property resolution at all. Nil then
// reads as success in both directions: `LeafSerializer`'s conditional guard is
// `(evaluated.bool ?? false) || (!evaluated.isNil && …)`, so `#if(rows.isEmpty)`
// never fires, while `ParameterResolver`'s `.not` is `rhs.bool ?? !rhs.isNil`,
// so `#if(!rows.isEmpty)` always fires.
//
// Thirty-three sites across 22 templates shipped that way. A render test could
// not see any of them: the template resolves, returns 200, and simply shows the
// wrong branch — a header-only table promising rows and listing none. So
// asserting a page renders proves nothing here; the assertion has to be that
// the empty COPY is present and the table chrome is not.
//
// `scripts/check-leaf-semantics.sh` blocks the idiom statically. This is the
// behavioural half: it fails if the working `count()` form is ever swapped back
// for something that silently resolves to nil.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class LeafEmptyStateRenderTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-leaf-empty")
    }

    /// With no courses open for enrollment, the student must be told so — not
    /// handed the enrollment form with an empty course list inside it.
    @Test func enrollPageWithNoCoursesRendersItsEmptyState() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "leaf_empty_enroll", password: "pw",
                role: "user", on: app)
            try await app.asyncTest(
                .GET, "/enroll",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("No courses are available to enroll in right now"))
                    // The submit control belongs to the form the empty state replaces.
                    #expect(!html.contains("action=\"/enroll\""))
                })
        }
    }

    /// The admin landing page lists courses. With none, the empty state must
    /// stand in place of the table — a table head with no body reads as
    /// "courses exist and something is broken".
    @Test func adminPageWithNoCoursesRendersItsEmptyState() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "leaf_empty_admin", password: "pw",
                role: "admin", on: app)
            try await app.asyncTest(
                .GET, "/admin",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("No courses yet."))
                    #expect(!html.contains("id=\"courses-table\""))
                })
        }
    }

    /// A COMPUTED property is the same nil, reached a different way. Swift's
    /// synthesized `Encodable` conformance encodes stored properties only, so
    /// `var assignmentCount: Int { assignments.count }` never reached the Leaf
    /// context and `#(assignmentCount)` rendered as the empty string — the new
    /// course page read "Assignments ()" directly above a working
    /// "Enrolled students (0)". It renders through `count()` now.
    @Test func assignmentHeadingCountRendersRatherThanVanishing() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "leaf_empty_course_count", password: "pw",
                role: "admin", on: app)
            try await app.asyncTest(
                .GET, "/admin/courses/new",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Assignments (0)"))
                    #expect(!html.contains("Assignments ()"))
                })
        }
    }

    /// The negated form is the other half of the defect, and it fails the
    /// opposite way: the block renders unconditionally. On a user enrolled in
    /// nothing, the admin user page must show the empty state rather than an
    /// enrolled-courses table with no rows.
    @Test func adminUserPageWithNoEnrollmentsRendersItsEmptyState() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "leaf_empty_admin_user", password: "pw",
                role: "admin", on: app)
            let subject = try await makeTestStudent(on: app, username: "leaf_empty_subject")
            let subjectID = try subject.requireID().uuidString
            try await app.asyncTest(
                .GET, "/admin/users/\(subjectID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("Not enrolled in any courses."))
                })
        }
    }
}
