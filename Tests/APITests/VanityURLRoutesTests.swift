// Tests/APITests/VanityURLRoutesTests.swift
//
// Tests for GET /:courseCode/:assignmentSlug vanity URL redirects.

import XCTest
import XCTVapor
@testable import chickadee_server
import Fluent
import Foundation

final class VanityURLRoutesTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = try await Application.make(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-vanity-\(UUID().uuidString)/")
            .path
        let dirs = ["results/", "testsetups/", "submissions/"].map { tmpDir + $0 }
        for dir in dirs {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        app.resultsDirectory     = dirs[0]
        app.testSetupsDirectory  = dirs[1]
        app.submissionsDirectory = dirs[2]

        app.sessions.use(.memory)
        app.middleware.use(app.sessions.middleware)
        try await configureTestDatabase(app)
        configureLeaf(app)
        try routes(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(atPath: tmpDir)
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
            zipPath: tmpDir + "testsetups/\(setupID).zip",
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

        let cookie = try await loginUser(username: "vanity_student1", password: "pw",
                                         role: "student", on: app)
        try await app.asyncTest(.GET, "/hlth230/lab-1", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/testsetups/setup_van02/notebook")
        })
    }

    func testVanityURL_caseInsensitiveCourseCode() async throws {
        // Course code stored as "CS246"; URL uses lowercase "cs246".
        let course = try await seedCourse(code: "cs246")
        let courseID = try course.requireID()
        try await seedSetupAndAssignment(courseID: courseID, title: "Assignment 2", setupID: "setup_van03")

        let cookie = try await loginUser(username: "vanity_student2", password: "pw",
                                         role: "student", on: app)
        try await app.asyncTest(.GET, "/cs246/assignment-2", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/testsetups/setup_van03/notebook")
        })
    }

    func testVanityURL_slugStripsSpecialChars() async throws {
        let course = try await seedCourse(code: "HLTH230")
        let courseID = try course.requireID()
        // Title "Lab 1: Intro" should match slug "lab-1-intro"
        try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1: Intro", setupID: "setup_van04")

        let cookie = try await loginUser(username: "vanity_student3", password: "pw",
                                         role: "student", on: app)
        try await app.asyncTest(.GET, "/hlth230/lab-1-intro", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/testsetups/setup_van04/notebook")
        })
    }

    func testVanityURL_archivedCourse_returns404() async throws {
        let course = try await seedCourse(code: "HLTH230", archived: true)
        let courseID = try course.requireID()
        try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1", setupID: "setup_van05")

        let cookie = try await loginUser(username: "vanity_student4", password: "pw",
                                         role: "student", on: app)
        try await app.asyncTest(.GET, "/hlth230/lab-1", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    func testVanityURL_unknownCourse_returns404() async throws {
        let cookie = try await loginUser(username: "vanity_student5", password: "pw",
                                         role: "student", on: app)
        try await app.asyncTest(.GET, "/nosuchcourse/lab-1", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    func testVanityURL_unknownAssignment_returns404() async throws {
        let course = try await seedCourse(code: "HLTH230")
        let courseID = try course.requireID()
        try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1", setupID: "setup_van06")

        let cookie = try await loginUser(username: "vanity_student6", password: "pw",
                                         role: "student", on: app)
        try await app.asyncTest(.GET, "/hlth230/lab99", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
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

        let cookie = try await loginUser(username: "vanity_student7", password: "pw",
                                         role: "student", on: app)
        try await app.asyncTest(.GET, "/hlth230/lab-1", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
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

        let cookie = try await loginUser(username: "vanity_student8", password: "pw",
                                         role: "student", on: app)
        try await app.asyncTest(.GET, "/hlth230/lab-1", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/testsetups/setup_van09/notebook")
        })

        try await app.asyncTest(.GET, "/hlth230/renamed-lab", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
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

        let cookie = try await loginUser(username: "vanity_student9", password: "pw",
                                         role: "student", on: app)
        try await app.asyncTest(.GET, "/hlth230/lab-1/submit", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/testsetups/setup_van11/submit")
        })

        try await app.asyncTest(.GET, "/hlth230/lab-1/history", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/testsetups/setup_van11/history")
        })
    }
}
