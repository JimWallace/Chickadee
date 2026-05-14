// Tests/APITests/SectionRoutesTests.swift
//
// Integration tests for AssignmentRoutes+Sections:
//   POST /instructor/sections                      — create section
//   POST /instructor/sections/reorder              — reorder sections
//   POST /instructor/sections/:sectionID/rename    — rename / reconfigure section
//   POST /instructor/sections/:sectionID/delete    — delete section
//   POST /instructor/:assignmentID/section         — move assignment to section

import XCTest
import XCTVapor
@testable import chickadee_server
import Fluent
import Foundation
import Core

final class SectionRoutesTests: XCTestCase {

    private var app: Application!
    override func setUp() async throws {
        app = try await makeTestApp(prefix: "chickadee-sect")
    }

    override func tearDown() async throws {
        try await app.tearDownTestApp()
    }

    // MARK: - Helpers

    /// Creates an .auto course (auto-enrolls the instructor on login).
    @discardableResult
    private func makeCourse(code: String) async throws -> APICourse {
        let course = APICourse(code: code, name: "Course \(code)", enrollmentMode: .auto)
        try await course.save(on: app.db)
        return course
    }

    /// Creates a section in the given course.
    @discardableResult
    private func makeSection(name: String, mode: String = "worker",
                              order: Int = 1, courseID: UUID) async throws -> APICourseSection {
        let section = APICourseSection(name: name, defaultGradingMode: mode,
                                       sortOrder: order, courseID: courseID)
        try await section.save(on: app.db)
        return section
    }

    /// Creates a test setup + assignment in the given course.
    @discardableResult
    private func makeAssignment(setupID: String, title: String,
                                 courseID: UUID) async throws -> APIAssignment {
        let manifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10,"makefile":null,"gradingMode":"worker"}
        """
        let setup = APITestSetup(id: setupID, manifest: manifest,
                                  zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(testSetupID: setupID, title: title,
                                        dueAt: nil, isOpen: true, courseID: courseID)
        try await assignment.save(on: app.db)
        return assignment
    }

    // MARK: - POST /instructor/sections — create

    func testCreateSection_instructorCanCreateSection() async throws {
        let course = try await makeCourse(code: "SECT_CREATE1")
        let courseID = try course.requireID()
        let cookie = try await loginUser(username: "sect_instructor1", password: "pw",
                                          role: "instructor", on: app)
        let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/sections", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(
                ["name": "Labs", "defaultGradingMode": "browser", "_csrf": token],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let sections = try await APICourseSection.query(on: app.db)
            .filter(\.$courseID == courseID)
            .all()
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].name, "Labs")
        XCTAssertEqual(sections[0].defaultGradingMode, "browser")
        XCTAssertEqual(sections[0].sortOrder, 1)
    }

    func testCreateSection_secondSectionGetsHigherSortOrder() async throws {
        let course = try await makeCourse(code: "SECT_CREATE2")
        let courseID = try course.requireID()
        try await makeSection(name: "Existing", order: 1, courseID: courseID)

        let cookie = try await loginUser(username: "sect_instructor2", password: "pw",
                                          role: "instructor", on: app)
        let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/sections", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(
                ["name": "Exams", "defaultGradingMode": "worker", "_csrf": token],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let exams = try await APICourseSection.query(on: app.db)
            .filter(\.$courseID == courseID)
            .filter(\.$name == "Exams")
            .first()
        XCTAssertEqual(exams?.sortOrder, 2)
    }

    func testCreateSection_emptyNameRejected() async throws {
        try await makeCourse(code: "SECT_EMPTY")
        let cookie = try await loginUser(username: "sect_instructor3", password: "pw",
                                          role: "instructor", on: app)
        let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/sections", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(
                ["name": "   ", "defaultGradingMode": "worker", "_csrf": token],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testCreateSection_invalidGradingModeRejected() async throws {
        try await makeCourse(code: "SECT_BADMODE")
        let cookie = try await loginUser(username: "sect_instructor4", password: "pw",
                                          role: "instructor", on: app)
        let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/sections", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(
                ["name": "Labs", "defaultGradingMode": "jupyter", "_csrf": token],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testCreateSection_studentForbidden() async throws {
        try await makeCourse(code: "SECT_STUDENT1")
        let cookie = try await loginUser(username: "sect_student1", password: "pw",
                                          role: "student", on: app)
        let (token, newCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/sections", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(
                ["name": "Labs", "defaultGradingMode": "worker", "_csrf": token],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            // Redirected to login (role middleware) or 403.
            XCTAssertTrue(res.status == .seeOther || res.status == .forbidden)
        })
    }

    // MARK: - POST /instructor/sections/reorder

    func testReorderSections_updatesOrder() async throws {
        let course = try await makeCourse(code: "SECT_REORDER1")
        let courseID = try course.requireID()
        let s1 = try await makeSection(name: "A", order: 1, courseID: courseID)
        let s2 = try await makeSection(name: "B", order: 2, courseID: courseID)
        let s3 = try await makeSection(name: "C", order: 3, courseID: courseID)
        let id1 = try s1.requireID().uuidString
        let id2 = try s2.requireID().uuidString
        let id3 = try s3.requireID().uuidString

        let cookie = try await loginUser(username: "sect_instructor_ro", password: "pw",
                                          role: "instructor", on: app)
        let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        // Reverse the order: C, B, A
        struct ReorderBody: Content { var sectionIDs: [String] }
        try await app.asyncTest(.POST, "/instructor/sections/reorder", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            req.headers.add(name: "x-csrf-token", value: token)
            req.headers.contentType = .json
            try req.content.encode(ReorderBody(sectionIDs: [id3, id2, id1]))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })

        let updated = try await APICourseSection.query(on: app.db)
            .filter(\.$courseID == courseID)
            .sort(\.$sortOrder)
            .all()
        XCTAssertEqual(updated.map { $0.name }, ["C", "B", "A"])
    }

    func testReorderSections_invalidUUIDRejected() async throws {
        try await makeCourse(code: "SECT_REORDER2")
        let cookie = try await loginUser(username: "sect_instructor_ri", password: "pw",
                                          role: "instructor", on: app)
        let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        struct ReorderBody: Content { var sectionIDs: [String] }
        try await app.asyncTest(.POST, "/instructor/sections/reorder", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            req.headers.add(name: "x-csrf-token", value: token)
            req.headers.contentType = .json
            try req.content.encode(ReorderBody(sectionIDs: ["not-a-uuid"]))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    // MARK: - POST /instructor/sections/:sectionID/rename

    func testRenameSection_updatesNameAndMode() async throws {
        let course = try await makeCourse(code: "SECT_RENAME1")
        let courseID = try course.requireID()
        let section = try await makeSection(name: "OldName", mode: "worker",
                                             order: 1, courseID: courseID)
        let sectionID = try section.requireID().uuidString

        let cookie = try await loginUser(username: "sect_instructor_rn", password: "pw",
                                          role: "instructor", on: app)
        let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/sections/\(sectionID)/rename",
                                beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(
                ["name": "NewName", "defaultGradingMode": "browser", "_csrf": token],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let updated = try await APICourseSection.find(section.id, on: app.db)
        XCTAssertEqual(updated?.name, "NewName")
        XCTAssertEqual(updated?.defaultGradingMode, "browser")
    }

    func testRenameSection_emptyNameRejected() async throws {
        let course = try await makeCourse(code: "SECT_RENAME2")
        let courseID = try course.requireID()
        let section = try await makeSection(name: "Good", order: 1, courseID: courseID)
        let sectionID = try section.requireID().uuidString

        let cookie = try await loginUser(username: "sect_instructor_rne", password: "pw",
                                          role: "instructor", on: app)
        let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/sections/\(sectionID)/rename",
                                beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(
                ["name": "", "defaultGradingMode": "worker", "_csrf": token],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testRenameSection_notFoundForUnknownID() async throws {
        try await makeCourse(code: "SECT_RENAME3")
        let cookie = try await loginUser(username: "sect_instructor_rnf", password: "pw",
                                          role: "instructor", on: app)
        let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        let randomID = UUID().uuidString
        try await app.asyncTest(.POST, "/instructor/sections/\(randomID)/rename",
                                beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(
                ["name": "Anything", "defaultGradingMode": "worker", "_csrf": token],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    // MARK: - POST /instructor/sections/:sectionID/delete

    func testDeleteSection_removesSection() async throws {
        let course = try await makeCourse(code: "SECT_DEL1")
        let courseID = try course.requireID()
        let section = try await makeSection(name: "ToDelete", order: 1, courseID: courseID)
        let sectionID = try section.requireID()

        let cookie = try await loginUser(username: "sect_instructor_del", password: "pw",
                                          role: "instructor", on: app)
        let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/sections/\(sectionID.uuidString)/delete",
                                beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(["_csrf": token], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let deleted = try await APICourseSection.find(sectionID, on: app.db)
        XCTAssertNil(deleted)
    }

    func testDeleteSection_assignmentsBecomesUngrouped() async throws {
        let course = try await makeCourse(code: "SECT_DEL2")
        let courseID = try course.requireID()
        let section = try await makeSection(name: "Doomed", order: 1, courseID: courseID)
        let sectionID = try section.requireID()

        // Create an assignment in that section.
        let assignment = try await makeAssignment(setupID: "del_setup1",
                                                   title: "Assigned", courseID: courseID)
        assignment.sectionID = sectionID
        try await assignment.save(on: app.db)

        let cookie = try await loginUser(username: "sect_instructor_del2", password: "pw",
                                          role: "instructor", on: app)
        let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/sections/\(sectionID.uuidString)/delete",
                                beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(["_csrf": token], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        // The assignment should still exist but be ungrouped.
        let updated = try await APIAssignment.find(assignment.id, on: app.db)
        XCTAssertNotNil(updated)
        XCTAssertNil(updated?.sectionID)
    }

    // MARK: - POST /instructor/:assignmentID/section

    func testMoveToSection_setsSection() async throws {
        let course = try await makeCourse(code: "SECT_MOVE1")
        let courseID = try course.requireID()
        let section = try await makeSection(name: "Target", order: 1, courseID: courseID)
        let sectionID = try section.requireID()
        let assignment = try await makeAssignment(setupID: "move_setup1",
                                                   title: "Moveable", courseID: courseID)
        let publicID = assignment.publicID

        let cookie = try await loginUser(username: "sect_instructor_mv", password: "pw",
                                          role: "instructor", on: app)
        let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        struct MoveBody: Content { var sectionID: String }
        try await app.asyncTest(.POST, "/instructor/\(publicID)/section", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            req.headers.add(name: "x-csrf-token", value: token)
            req.headers.contentType = .json
            try req.content.encode(MoveBody(sectionID: sectionID.uuidString))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })

        let updated = try await APIAssignment.find(assignment.id, on: app.db)
        XCTAssertEqual(updated?.sectionID, sectionID)
    }

    func testMoveToSection_emptyIDClearsSection() async throws {
        let course = try await makeCourse(code: "SECT_MOVE2")
        let courseID = try course.requireID()
        let section = try await makeSection(name: "ASection", order: 1, courseID: courseID)
        let sectionID = try section.requireID()
        let assignment = try await makeAssignment(setupID: "move_setup2",
                                                   title: "Moveable2", courseID: courseID)
        assignment.sectionID = sectionID
        try await assignment.save(on: app.db)
        let publicID = assignment.publicID

        let cookie = try await loginUser(username: "sect_instructor_mv2", password: "pw",
                                          role: "instructor", on: app)
        let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        struct MoveBody: Content { var sectionID: String }
        try await app.asyncTest(.POST, "/instructor/\(publicID)/section", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            req.headers.add(name: "x-csrf-token", value: token)
            req.headers.contentType = .json
            try req.content.encode(MoveBody(sectionID: ""))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })

        let updated = try await APIAssignment.find(assignment.id, on: app.db)
        XCTAssertNil(updated?.sectionID)
    }

    func testMoveToSection_syncsBrowserGradingMode() async throws {
        let course = try await makeCourse(code: "SECT_MOVE3")
        let courseID = try course.requireID()
        let section = try await makeSection(name: "BrowserSection", mode: "browser",
                                             order: 1, courseID: courseID)
        let sectionID = try section.requireID()

        // Create assignment with a manifest that has gradingMode = "worker"
        let manifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10,"makefile":null,"gradingMode":"worker"}
        """
        let setupID = "move_setup3"
        let setup = APITestSetup(id: setupID, manifest: manifest,
                                  zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(testSetupID: setupID, title: "GradeModeTest",
                                        dueAt: nil, isOpen: true, courseID: courseID)
        try await assignment.save(on: app.db)
        let publicID = assignment.publicID

        let cookie = try await loginUser(username: "sect_instructor_mv3", password: "pw",
                                          role: "instructor", on: app)
        let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        struct MoveBody: Content { var sectionID: String }
        try await app.asyncTest(.POST, "/instructor/\(publicID)/section", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            req.headers.add(name: "x-csrf-token", value: token)
            req.headers.contentType = .json
            try req.content.encode(MoveBody(sectionID: sectionID.uuidString))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })

        // The test setup manifest should now have gradingMode = "browser"
        let updatedSetup = try await APITestSetup.find(setup.id, on: app.db)
        let manifestData = Data((updatedSetup?.manifest ?? "").utf8)
        let dict = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        XCTAssertEqual(dict?["gradingMode"] as? String, "browser")
    }
}
