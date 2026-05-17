// Tests/APITests/VanityURLRoutesTests.swift
//
// Tests for GET /:courseCode/:assignmentSlug vanity URL redirects.

import Fluent
import Foundation
import XCTVapor
import XCTest

@testable import chickadee_server

final class VanityURLRoutesTests: XCTestCase {

    private var app: Application!
    override func setUp() async throws {
        app = try await makeTestApp(prefix: "chickadee-vanity")
    }

    override func tearDown() async throws {
        try await app.tearDownTestApp()
    }

    // MARK: - slugify

    func testSlugify_stripsSpaces() {
        XCTAssertEqual(VanityURLRoutes.slugify("Lab 1"), "lab-1")
    }

    func testSlugify_stripsSpecialChars() {
        XCTAssertEqual(VanityURLRoutes.slugify("Lab 1: Intro"), "lab-1-intro")
    }

    func testSlugify_lowercases() {
        XCTAssertEqual(VanityURLRoutes.slugify("Assignment2"), "assignment2")
    }

    func testSlugify_handlesHyphensAndSlashes() {
        XCTAssertEqual(VanityURLRoutes.slugify("A2 - Sorting/Searching"), "a2-sorting-searching")
    }

    func testSlugify_emptyString() {
        XCTAssertEqual(VanityURLRoutes.slugify(""), "")
    }

    // MARK: - Route helpers

    private func seedCourse(code: String, archived: Bool = false) async throws -> APICourse {
        let course = APICourse(code: code, name: "Course \(code)")
        course.isArchived = archived
        try await course.save(on: app.db)
        return course
    }

    /// Enrolls `username` (creating the row only if the user already exists)
    /// in `course`. Most vanity-URL tests use student accounts, which need
    /// course enrollment to clear the resolver's enrollment gate; previously
    /// the resolver was missing this check and an unenrolled student saw the
    /// same 303 redirect as an enrolled one, which leaked the course/slug
    /// catalogue (issue #561).
    private func enrollStudent(username: String, in course: APICourse) async throws {
        guard
            let user = try await APIUser.query(on: app.db).filter(\.$username == username).first()
        else {
            XCTFail("user \(username) not found; call loginUser first")
            return
        }
        let userID = try user.requireID()
        let courseID = try course.requireID()
        let exists =
            try await APICourseEnrollment.query(on: app.db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == courseID)
            .count() > 0
        if exists { return }
        try await APICourseEnrollment(userID: userID, courseID: courseID).save(on: app.db)
    }

    @discardableResult
    private func seedSetupAndAssignment(
        courseID: UUID,
        title: String,
        setupID: String
    ) async throws -> APIAssignment {
        let manifest = """
            {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
            """
        let setup = APITestSetup(
            id: setupID,
            manifest: manifest,
            zipPath: app.testSetupsDirectory + "\(setupID).zip",
            courseID: courseID
        )
        try await setup.save(on: app.db)

        let assignment = APIAssignment(testSetupID: setupID, title: title, isOpen: true, courseID: courseID)
        try await assignment.save(on: app.db)
        return assignment
    }

    // MARK: - Unauthenticated

    func testVanityURL_unauthenticated_redirectsToLogin() async throws {
        let course = try await seedCourse(code: "HLTH230")
        let courseID = try course.requireID()
        try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1", setupID: "setup_van01")

        try await app.asyncTest(.GET, "/hlth230/lab-1") { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/login")
        }
    }

    // MARK: - Authenticated

    func testVanityURL_redirectsToNotebook() async throws {
        let course = try await seedCourse(code: "HLTH230")
        let courseID = try course.requireID()
        try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1", setupID: "setup_van02")

        let cookie = try await loginUser(
            username: "vanity_student1", password: "pw",
            role: "student", on: app)
        try await enrollStudent(username: "vanity_student1", in: course)
        try await app.asyncTest(
            .GET, "/hlth230/lab-1",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/testsetups/setup_van02/notebook")
            })
    }

    func testVanityURL_caseInsensitiveCourseCode() async throws {
        // Course code stored as "CS246"; URL uses lowercase "cs246".
        let course = try await seedCourse(code: "cs246")
        let courseID = try course.requireID()
        try await seedSetupAndAssignment(courseID: courseID, title: "Assignment 2", setupID: "setup_van03")

        let cookie = try await loginUser(
            username: "vanity_student2", password: "pw",
            role: "student", on: app)
        try await enrollStudent(username: "vanity_student2", in: course)
        try await app.asyncTest(
            .GET, "/cs246/assignment-2",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/testsetups/setup_van03/notebook")
            })
    }

    func testVanityURL_slugStripsSpecialChars() async throws {
        let course = try await seedCourse(code: "HLTH230")
        let courseID = try course.requireID()
        // Title "Lab 1: Intro" should match slug "lab-1-intro"
        try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1: Intro", setupID: "setup_van04")

        let cookie = try await loginUser(
            username: "vanity_student3", password: "pw",
            role: "student", on: app)
        try await enrollStudent(username: "vanity_student3", in: course)
        try await app.asyncTest(
            .GET, "/hlth230/lab-1-intro",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/testsetups/setup_van04/notebook")
            })
    }

    func testVanityURL_archivedCourse_returns404() async throws {
        let course = try await seedCourse(code: "HLTH230", archived: true)
        let courseID = try course.requireID()
        try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1", setupID: "setup_van05")

        let cookie = try await loginUser(
            username: "vanity_student4", password: "pw",
            role: "student", on: app)
        try await app.asyncTest(
            .GET, "/hlth230/lab-1",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
    }

    func testVanityURL_unknownCourse_returns404() async throws {
        let cookie = try await loginUser(
            username: "vanity_student5", password: "pw",
            role: "student", on: app)
        try await app.asyncTest(
            .GET, "/nosuchcourse/lab-1",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
    }

    func testVanityURL_unknownAssignment_returns404() async throws {
        let course = try await seedCourse(code: "HLTH230")
        let courseID = try course.requireID()
        try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1", setupID: "setup_van06")

        let cookie = try await loginUser(
            username: "vanity_student6", password: "pw",
            role: "student", on: app)
        try await enrollStudent(username: "vanity_student6", in: course)
        try await app.asyncTest(
            .GET, "/hlth230/lab99",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
    }

    func testVanityURL_activeCourseShadowsArchived() async throws {
        // Two courses with the same code — only the active one should match.
        let archived = try await seedCourse(code: "HLTH230", archived: true)
        let archivedID = try archived.requireID()
        try await seedSetupAndAssignment(courseID: archivedID, title: "Lab 1", setupID: "setup_van07")

        let active = try await seedCourse(code: "HLTH230", archived: false)
        let activeID = try active.requireID()
        try await seedSetupAndAssignment(courseID: activeID, title: "Lab 1", setupID: "setup_van08")

        let cookie = try await loginUser(
            username: "vanity_student7", password: "pw",
            role: "student", on: app)
        try await enrollStudent(username: "vanity_student7", in: active)
        try await app.asyncTest(
            .GET, "/hlth230/lab-1",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/testsetups/setup_van08/notebook")
            })
    }

    func testVanityURL_usesPersistedSlugAfterTitleRename() async throws {
        let course = try await seedCourse(code: "HLTH230")
        let courseID = try course.requireID()
        let assignment = try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1", setupID: "setup_van09")
        assignment.title = "Renamed Lab"
        try await assignment.save(on: app.db)

        let cookie = try await loginUser(
            username: "vanity_student8", password: "pw",
            role: "student", on: app)
        try await enrollStudent(username: "vanity_student8", in: course)
        try await app.asyncTest(
            .GET, "/hlth230/lab-1",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/testsetups/setup_van09/notebook")
            })

        try await app.asyncTest(
            .GET, "/hlth230/renamed-lab",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
    }

    func testUniqueAssignmentSlug_suffixesDuplicateTitlesInCourse() async throws {
        let course = try await seedCourse(code: "HLTH230")
        let courseID = try course.requireID()
        try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1", setupID: "setup_van10")

        let slug = try await uniqueAssignmentSlug(title: "Lab 1", courseID: courseID, db: app.db)
        XCTAssertEqual(slug, "lab-1-2")
    }

    func testVanityURL_submitAndHistoryRoutesRedirectToCanonicalStudentRoutes() async throws {
        let course = try await seedCourse(code: "HLTH230")
        let courseID = try course.requireID()
        try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1", setupID: "setup_van11")

        let cookie = try await loginUser(
            username: "vanity_student9", password: "pw",
            role: "student", on: app)
        try await enrollStudent(username: "vanity_student9", in: course)
        try await app.asyncTest(
            .GET, "/hlth230/lab-1/submit",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/testsetups/setup_van11/submit")
            })

        try await app.asyncTest(
            .GET, "/hlth230/lab-1/history",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/testsetups/setup_van11/history")
            })
    }

    // MARK: - Enrollment gate (issue #561)

    func testVanityURL_unenrolledStudent_returns404() async throws {
        // Regression: an unenrolled student receives the SAME 404 as a typo
        // so they cannot distinguish "course/slug doesn't exist" from
        // "course/slug exists but I'm not in that class." This closes the
        // catalogue-enumeration vector documented in issue #561.
        let course = try await seedCourse(code: "HLTH230")
        let courseID = try course.requireID()
        try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1", setupID: "setup_van12")

        let cookie = try await loginUser(
            username: "vanity_outsider1", password: "pw",
            role: "student", on: app)
        // Deliberately NOT calling enrollStudent here.
        try await app.asyncTest(
            .GET, "/hlth230/lab-1",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
    }

    func testVanityURL_unenrolledStudent_unknownSlug_alsoReturns404() async throws {
        // Companion to the prior test: confirms the enrollment gate fires
        // BEFORE the slug lookup, so an unenrolled student with a typo slug
        // gets the same 404 as with a valid slug. Otherwise the timing /
        // response difference between "valid slug, 404" and "invalid slug,
        // 404" would still leak slug existence.
        let course = try await seedCourse(code: "HLTH230")
        let courseID = try course.requireID()
        try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1", setupID: "setup_van13")

        let cookie = try await loginUser(
            username: "vanity_outsider2", password: "pw",
            role: "student", on: app)
        try await app.asyncTest(
            .GET, "/hlth230/no-such-slug",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
    }

    func testVanityURL_instructor_bypassesEnrollmentCheck() async throws {
        // Instructors and admins can preview / test any course's vanity URL
        // without being enrolled — required by the "test my own assignment"
        // and cross-course audit flows.
        let course = try await seedCourse(code: "HLTH230")
        let courseID = try course.requireID()
        try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1", setupID: "setup_van14")

        let cookie = try await loginUser(
            username: "vanity_instructor1", password: "pw",
            role: "instructor", on: app)
        // Deliberately NOT enrolling — instructors bypass the check.
        try await app.asyncTest(
            .GET, "/hlth230/lab-1",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/testsetups/setup_van14/notebook")
            })
    }
}
