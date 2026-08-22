// Tests/APITests/AccountRoutesTests.swift
//
// Integration tests for AccountRoutes:
//   POST /account/unenroll/:courseID   — leave a course
//
// Key behaviours under test:
//   - Only open-mode courses can be self-left (closed and auto return 403)
//   - Leaving does NOT delete submissions
//   - Unauthenticated access redirects to /login
//   - Invalid course ID returns 400; unknown ID returns 404

import Core
import Crypto
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AccountRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-acct")
    }

    // MARK: - Helpers

    private func makeCourse(code: String, mode: CourseEnrollmentMode = .open) async throws -> APICourse {
        try await makeTestCourse(on: app, code: code, mode: mode)
    }

    private func makeStudent(username: String) async throws -> APIUser {
        try await makeTestStudent(on: app, username: username)
    }

    private func enroll(user: APIUser, in course: APICourse) async throws {
        let e = APICourseEnrollment(userID: try user.requireID(), courseID: try course.requireID())
        try await e.save(on: app.db)
    }

    private func enrollmentCount(user: APIUser, in course: APICourse) async throws -> Int {
        try await APICourseEnrollment.query(on: app.db)
            .filter(\.$userID == user.requireID())
            .filter(\.$course.$id == course.requireID())
            .count()
    }

    // MARK: - Unauthenticated access

    @Test func leaveCourse_unauthenticated_redirectsToLogin() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "UNAUTH_LEAVE")
            let courseID = try course.requireID().uuidString
            try await app.asyncTest(.POST, "/account/unenroll/\(courseID)") { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/login")
            }

        }
    }

    // MARK: - Empty states actually render

    /// Regression: both sections used `#if(rows.isEmpty)` in Leaf, which never
    /// fires. LeafKit has no property resolution for `.isEmpty` on an array —
    /// the path resolves to nil, so the test is always false and its negation
    /// always true. The page therefore rendered "Available courses" as a
    /// heading over a table with column headers and no rows, promising courses
    /// and listing none. Emptiness is decided in Swift now; this pins it.
    @Test func emptyCourseListsRenderTheirEmptyStateNotAHeaderOnlyTable() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "acct_empty_states", password: "pw",
                role: "student", on: app)
            try await app.asyncTest(
                .GET, "/account",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("You are not enrolled in any courses"))
                    #expect(html.contains("There are no other courses open to join right now"))
                    // A table would carry the column header; the empty state
                    // must replace it, not sit beside it.
                    #expect(!html.contains("<th>Code</th>"))
                })
        }
    }

    // MARK: - The avatar renders

    /// The bird reaches the page, from the sprite through the partial.
    ///
    /// Worth an end-to-end assertion rather than trusting the unit tests: a
    /// Leaf partial that fails to resolve, or an interpolation that lexes
    /// differently than it reads, produces a page that still returns 200. The
    /// specific things checked are the ones that would be silently wrong — the
    /// sprite present, the five layers stacked, the wing fragment actually
    /// interpolated (not emitted literally), and the palette assigned as
    /// custom properties rather than colours.
    @Test func accountPageRendersTheStudentsChickadee() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "acct_avatar", password: "pw", role: "student", on: app)
            try await app.asyncTest(
                .GET, "/account",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("<symbol id=\"av-plumage\""), "sprite missing")
                    #expect(html.contains("class=\"avatar\""))
                    for layer in ["#av-backdrop", "#av-plumage", "#av-beak", "#av-eyes"] {
                        #expect(html.contains("<use href=\"\(layer)\"/>"), "no \(layer) layer")
                    }
                    // The wing is the interpolated one: a wing symbol must
                    // appear and the interpolation must not survive as text.
                    #expect(html.contains("<use href=\"#av-wing-"), "wing not interpolated")
                    #expect(!html.contains("wingSymbolRef"), "interpolation survived as text")
                    #expect(!html.contains("href=\"\""), "a layer reference resolved to empty")
                    #expect(html.contains("--av-cap: var(--avatar-"))
                    // The monogram this replaced is gone, not merely hidden.
                    #expect(!html.contains("account-monogram"))
                })
        }
    }

    /// A student sees the handle reserved for them in each course, named as a
    /// noun phrase rather than a sentence — the shape the slip-day line beside
    /// it already uses, where the phrase carries its own noun.
    @Test func accountPageShowsThePerCourseHandleAndItsLimits() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "AVATARC")
            let cookie = try await loginUser(
                username: "acct_handle", password: "pw", role: "student", on: app)
            let user = try #require(
                try await APIUser.query(on: app.db)
                    .filter(\.$username == "acct_handle").first())
            try await enroll(user: user, in: course)

            // First load materializes the handle.
            try await app.asyncTest(
                .GET, "/account",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.status == .ok) })

            let handle = try #require(
                try await APICourseEnrollment.query(on: app.db)
                    .filter(\.$userID == user.requireID()).first()?.avatarHandle)
            #expect(AvatarHandle.isWellFormed(handle))

            // Second load shows it, and says what it does not promise.
            try await app.asyncTest(
                .GET, "/account",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    let html = res.body.string
                    #expect(html.contains("Class handle: \(handle)"))
                })
        }
    }

    /// The fully-populated identity header — the state the design shows, and
    /// the one the pixel baseline CANNOT draw: display name, student ID and
    /// email arrive from SSO claims, and no HTTP route sets them, so the
    /// visual-regression fixture (which speaks only HTTP) renders a bare local
    /// account. This asserts the populated rendering end to end instead.
    @Test func populatedIdentityRendersNameUsernameAndEveryDetailRow() async throws {
        try await withApp(app) { _ in
            let hash = try testPasswordHash("pw")
            let user = APIUser(
                username: "a4student", passwordHash: hash, role: "user",
                email: "a4student@uwaterloo.ca", preferredName: "Avery",
                studentID: "20824417", displayName: "Avery Sandoval")
            try await user.save(on: app.db)
            let cookie = try await loginUser(
                username: "a4student", password: "pw", role: "user", on: app)
            try await app.asyncTest(
                .GET, "/account",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    // Heading is the display name; the username sits under it.
                    #expect(html.contains("<strong>Avery Sandoval</strong>"))
                    #expect(html.contains(#"<span class="text-muted">a4student</span>"#))
                    // All four detail rows.
                    #expect(html.contains("Preferred name"))
                    #expect(html.contains("Avery"))
                    #expect(html.contains("Student ID"))
                    #expect(html.contains("20824417"))
                    #expect(html.contains("a4student@uwaterloo.ca"))
                })
        }
    }

    /// A local account with nothing on file must not print its username twice.
    @Test func bareAccountShowsTheUsernameOnceWithNoSecondaryLine() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "bare_account", password: "pw", role: "user", on: app)
            try await app.asyncTest(
                .GET, "/account",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("<strong>bare_account</strong>"))
                    #expect(!html.contains(#"<span class="text-muted">bare_account</span>"#))
                })
        }
    }

    // MARK: - Invalid / missing course

    @Test func leaveCourse_invalidCourseID_returns400() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "leave_bad_id", password: "pw",
                role: "student", on: app)
            let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/account/unenroll/not-a-uuid",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                })

        }
    }

    @Test func leaveCourse_unknownCourseID_returns404() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "leave_unknown", password: "pw",
                role: "student", on: app)
            let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
            let bogus = UUID().uuidString
            try await app.asyncTest(
                .POST, "/account/unenroll/\(bogus)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    // MARK: - Mode enforcement

    @Test func leaveCourse_openMode_removesEnrollment() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "LEAVE_OPEN", mode: .open)
            let student = try await makeStudent(username: "leave_open_s1")
            try await enroll(user: student, in: course)

            let cookie = try await loginUser(
                username: "leave_open_s1", password: "pw",
                role: "student", on: app)
            let courseID = try course.requireID().uuidString
            let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/account/unenroll/\(courseID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let count = try await enrollmentCount(user: student, in: course)
            #expect(count == 0, "Enrollment should be removed after leaving an open course")

        }
    }

    @Test func leaveCourse_closedMode_returns403() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "LEAVE_CLOSED", mode: .closed)
            let student = try await makeStudent(username: "leave_closed_s1")
            try await enroll(user: student, in: course)

            let cookie = try await loginUser(
                username: "leave_closed_s1", password: "pw",
                role: "student", on: app)
            let courseID = try course.requireID().uuidString
            let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/account/unenroll/\(courseID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden, "Closed-mode course: student should not be able to self-leave")
                })

            let count = try await enrollmentCount(user: student, in: course)
            #expect(count == 1, "Enrollment should remain after forbidden leave attempt")

        }
    }

    @Test func leaveCourse_autoMode_returns403() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "LEAVE_AUTO", mode: .auto)
            let student = try await makeStudent(username: "leave_auto_s1")
            try await enroll(user: student, in: course)

            let cookie = try await loginUser(
                username: "leave_auto_s1", password: "pw",
                role: "student", on: app)
            let courseID = try course.requireID().uuidString
            let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/account/unenroll/\(courseID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden, "Auto-mode course: student should not be able to self-leave")
                })

            let count = try await enrollmentCount(user: student, in: course)
            #expect(count == 1, "Enrollment should remain after forbidden leave attempt")

        }
    }

    // MARK: - Submissions preserved

    @Test func leaveCourse_preservesSubmissions() async throws {
        try await withApp(app) { _ in
            // Create a course and a test setup so we can create a submission.
            let course = try await makeCourse(code: "LEAVE_SUBS", mode: .open)
            let student = try await makeStudent(username: "leave_subs_s1")
            try await enroll(user: student, in: course)

            // Create a minimal test setup and submission record.
            let setupID = UUID().uuidString
            let zipPath = app.testSetupsDirectory + "\(setupID).zip"
            try Data("PK".utf8).write(to: URL(fileURLWithPath: zipPath))
            let manifest = """
                {"schemaVersion":1,"testSuites":[{"tier":"public","script":"t.sh"}],"timeLimitSeconds":5}
                """
            let setup = APITestSetup(
                id: setupID, manifest: manifest, zipPath: zipPath,
                courseID: try course.requireID())
            try await setup.save(on: app.db)

            let subID = UUID().uuidString
            let subZip = app.submissionsDirectory + "\(subID).zip"
            try Data("PK".utf8).write(to: URL(fileURLWithPath: subZip))
            let sub = APISubmission(
                id: subID, testSetupID: setupID, zipPath: subZip,
                attemptNumber: 1, status: "complete",
                filename: "sub.zip", userID: try student.requireID(),
                kind: APISubmission.Kind.student)
            try await sub.save(on: app.db)

            // Now leave the course.
            let cookie = try await loginUser(
                username: "leave_subs_s1", password: "pw",
                role: "student", on: app)
            let courseID = try course.requireID().uuidString
            let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/account/unenroll/\(courseID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            // Enrollment removed.
            let enrollCount = try await enrollmentCount(user: student, in: course)
            #expect(enrollCount == 0, "Enrollment should be removed")

            // Submission still exists.
            let subStillExists = try await APISubmission.find(subID, on: app.db)
            #expect(subStillExists != nil, "Submission must not be deleted when leaving a course")

        }
    }
}

/// The identity header resolves ONE name, used for the heading and the row, so
/// the two can never disagree. The username line under it is dropped when it would merely repeat the
/// heading — a local account with nothing on file would otherwise print its
/// username twice, which reads as a rendering fault rather than as identity.
@Suite struct AccountIdentityNameTests {

    @Test func prefersTheDisplayNameWhenTheIdPReleasedOne() {
        #expect(
            accountIdentityName(
                displayName: "Avery Sandoval", preferredName: "Avery", username: "a4student")
                == "Avery Sandoval")
    }

    @Test func fallsBackToPreferredNameThenUsername() {
        #expect(
            accountIdentityName(displayName: nil, preferredName: "Avery", username: "a4student")
                == "Avery")
        #expect(
            accountIdentityName(displayName: nil, preferredName: nil, username: "a4student")
                == "a4student")
    }

    @Test func treatsBlankAndWhitespaceNamesAsAbsent() {
        #expect(
            accountIdentityName(displayName: "", preferredName: "   ", username: "a4student")
                == "a4student")
    }

    @Test func secondaryLineIsDroppedWhenItWouldRepeatTheHeading() {
        #expect(
            accountIdentitySecondary(identityName: "a4student", username: "a4student") == nil)
        #expect(
            accountIdentitySecondary(identityName: "Avery Sandoval", username: "a4student")
                == "a4student")
    }
}
