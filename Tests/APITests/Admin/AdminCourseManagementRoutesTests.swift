// Tests/APITests/Admin/AdminCourseManagementRoutesTests.swift
//
// Admin course management routes: edit, copy (codes, sections and notebook
// paths), archive and unarchive, delete, and enrollment changes.
//
// Split out of AdminRoutesTests.swift; the helpers these suites share are in
// AdminRouteFixtures.swift.

import Core
import Fluent
import Foundation
import NIOFoundationCompat
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AdminCourseManagementRoutesTests: AdminRouteFixtures {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-courses")
    }

    // MARK: - Course edit, copy codes, archive, delete and enrollment

    @Test func editCourseUpdatesFields() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let course = try await makeCourse(code: "EDIT101", name: "Original Name")
            let courseID = try course.requireID()
            let (boundCookie, token) = try await csrfCookieAndToken(
                cookie, path: "/admin/courses/\(courseID.uuidString)")

            try await app.asyncTest(
                .POST, "/admin/courses/\(courseID.uuidString)/edit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(
                        ["code": "EDIT201", "name": "Updated Name", "_csrf": token],
                        as: .urlEncodedForm
                    )
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/admin/courses/\(courseID.uuidString)")
                })

            let updated = try await APICourse.find(courseID, on: app.db)
            #expect(updated?.code == "EDIT201")
            #expect(updated?.name == "Updated Name")

        }
    }

    @Test func copyCourseSkipsTakenCopyCodes() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let source = try await makeCourse(code: "CPY101", name: "Copy Source")
            // Occupy the first two candidate codes so the copy must fall
            // through to -COPY-3 — pins the candidate ordering of
            // uniqueCopyCode.
            try await makeCourse(code: "CPY101-COPY", name: "Existing Copy")
            try await makeCourse(code: "CPY101-COPY-2", name: "Existing Copy 2")
            let courseID = try source.requireID()
            let (boundCookie, token) = try await csrfCookieAndToken(
                cookie, path: "/admin/courses/\(courseID.uuidString)")

            try await app.asyncTest(
                .POST, "/admin/courses/\(courseID.uuidString)/copy",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let copied = try #require(
                try await APICourse.query(on: app.db).filter(\.$code == "CPY101-COPY-3").first())
            #expect(copied.name == "Copy Source (Copy)")
        }
    }

    /// The copy picks its code with the duplicate check every other door
    /// uses, so an active "cpy201-copy" in another case takes the first
    /// candidate (#2229).
    @Test func copyCourseSkipsACopyCodeTakenInAnotherCase() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let source = try await makeCourse(code: "CPY201", name: "Copy Source")
            try await makeCourse(code: "cpy201-copy", name: "Lower-case Copy")
            let courseID = try source.requireID()
            let (boundCookie, token) = try await csrfCookieAndToken(
                cookie, path: "/admin/courses/\(courseID.uuidString)")

            try await app.asyncTest(
                .POST, "/admin/courses/\(courseID.uuidString)/copy",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            #expect(try await APICourse.query(on: app.db).filter(\.$code == "CPY201-COPY").first() == nil)
            let copied = try #require(
                try await APICourse.query(on: app.db).filter(\.$code == "CPY201-COPY-2").first())
            #expect(copied.name == "Copy Source (Copy)")
        }
    }

    @Test func toggleCourseArchiveFlipsArchivedState() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let course = try await makeCourse(code: "ARCH101", name: "Archive Me", archived: false)
            let courseID = try course.requireID()
            let (boundCookie, token) = try await csrfCookieAndToken(
                cookie, path: "/admin/courses/\(courseID.uuidString)")

            try await app.asyncTest(
                .POST, "/admin/courses/\(courseID.uuidString)/archive",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let updated = try await APICourse.find(courseID, on: app.db)
            #expect(updated?.isArchived == true)

        }
    }

    /// Un-archiving re-enters the unique index over active courses. With an
    /// active course already holding the same code and term, the toggle
    /// reports a duplicate and leaves the course archived instead of failing
    /// on the index (#1777).
    @Test func unarchiveRefusesACodeAnActiveCourseAlreadyHolds() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let archived = try await makeCourse(code: "DUP101", name: "Old offering", archived: true)
            _ = try await makeCourse(code: "DUP101", name: "New offering", archived: false)
            let courseID = try archived.requireID()
            let (boundCookie, token) = try await csrfCookieAndToken(
                cookie, path: "/admin/courses/\(courseID.uuidString)")

            try await app.asyncTest(
                .POST, "/admin/courses/\(courseID.uuidString)/archive",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("error=code_taken") == true)
                })

            let still = try await APICourse.find(courseID, on: app.db)
            #expect(still?.isArchived == true)
        }
    }

    @Test func deleteCourseRemovesRecordsAndFilesForArchivedCourse() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let student = try await makeUser(username: "delete_student", role: "student")
            let studentID = try student.requireID()
            let course = try await makeCourse(code: "DEL101", name: "Delete Me", archived: true)
            // Past the 365-day retention window so deletion is permitted.
            course.archivedAt = Date().addingTimeInterval(-400 * 86_400)
            try await course.save(on: app.db)
            let courseID = try course.requireID()
            let setup = try await makeSetup(id: "setup_delete_admin", courseID: courseID)
            _ = try await makeAssignment(testSetupID: "setup_delete_admin", courseID: courseID)
            _ = try await makeEnrollment(userID: studentID, courseID: courseID)
            let submission = try await makeSubmission(
                id: "sub_delete_admin", setupID: "setup_delete_admin", userID: studentID)
            _ = try await makeResult(submissionID: try submission.requireID())
            let (boundCookie, token) = try await csrfCookieAndToken(
                cookie, path: "/admin/courses/\(courseID.uuidString)")

            try await app.asyncTest(
                .POST, "/admin/courses/\(courseID.uuidString)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.hasPrefix("/admin/retention") == true)
                })

            let deletedCourse = try await APICourse.find(courseID, on: app.db)
            let assignmentCount = try await APIAssignment.query(on: app.db).filter(\.$courseID == courseID).count()
            let setupCount = try await APITestSetup.query(on: app.db).filter(\.$courseID == courseID).count()
            let enrollmentCount = try await APICourseEnrollment.query(on: app.db).filter(\.$course.$id == courseID)
                .count()
            let submissionCount = try await APISubmission.query(on: app.db).filter(
                \.$testSetupID == "setup_delete_admin"
            )
            .count()
            let resultCount = try await APIResult.query(on: app.db).count()
            #expect(deletedCourse == nil)
            #expect(assignmentCount == 0)
            #expect(setupCount == 0)
            #expect(enrollmentCount == 0)
            #expect(submissionCount == 0)
            #expect(resultCount == 0)
            #expect(FileManager.default.fileExists(atPath: app.testSetupsDirectory + "setup_delete_admin.zip") == false)
            #expect(
                FileManager.default.fileExists(atPath: app.testSetupsDirectory + "setup_delete_admin.ipynb") == false)
            #expect(FileManager.default.fileExists(atPath: submission.zipPath) == false)
            _ = setup

        }
    }

    @Test func deleteCourseRejectedWhenRetentionWindowNotElapsed() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let course = try await makeCourse(code: "DELRECENT", name: "Recently Archived", archived: true)
            // Archived just now — well inside the retention window.
            course.archivedAt = Date()
            try await course.save(on: app.db)
            let courseID = try course.requireID()
            let (boundCookie, token) = try await csrfCookieAndToken(
                cookie, path: "/admin/courses/\(courseID.uuidString)")

            try await app.asyncTest(
                .POST, "/admin/courses/\(courseID.uuidString)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("error=") == true)
                })

            // The course must survive — deletion was refused.
            let survivor = try await APICourse.find(courseID, on: app.db)
            #expect(survivor != nil)
        }
    }

    @Test func adminEnrollAndUnenrollUserMutatesEnrollment() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let user = try await makeUser(username: "managed_student", role: "student")
            let userID = try user.requireID()
            let course = try await makeCourse(code: "ENROLL101", name: "Managed Course")
            let courseID = try course.requireID()

            let (enrollCookie, enrollToken) = try await csrfCookieAndToken(
                cookie, path: "/admin/users/\(userID.uuidString)")
            try await app.asyncTest(
                .POST, "/admin/users/\(userID.uuidString)/enroll",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: enrollCookie)
                    try req.content.encode(
                        ["courseID": courseID.uuidString, "_csrf": enrollToken],
                        as: .urlEncodedForm
                    )
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/admin/users/\(userID.uuidString)")
                })

            let enrollmentCountAfterEnroll = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == userID)
                .filter(\.$course.$id == courseID)
                .count()
            #expect(enrollmentCountAfterEnroll == 1)

            let (unenrollCookie, unenrollToken) = try await csrfCookieAndToken(
                cookie, path: "/admin/users/\(userID.uuidString)")
            try await app.asyncTest(
                .POST, "/admin/users/\(userID.uuidString)/unenroll/\(courseID.uuidString)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: unenrollCookie)
                    try req.content.encode(["_csrf": unenrollToken], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/admin/users/\(userID.uuidString)")
                })

            let enrollmentCountAfterUnenroll = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == userID)
                .filter(\.$course.$id == courseID)
                .count()
            #expect(enrollmentCountAfterUnenroll == 0)

        }
    }

    // MARK: - POST /admin/courses/:courseID/copy

    @Test func courseCopySectionsArePreserved() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let course = try await makeCourse(code: "CPSECT")
            let courseID = try course.requireID()

            // Two sections.
            let browserSec = APICourseSection(
                name: "Browser Labs", sortOrder: 1, courseID: courseID)
            try await browserSec.save(on: app.db)
            let workerSec = APICourseSection(
                name: "Worker Labs", sortOrder: 2, courseID: courseID)
            try await workerSec.save(on: app.db)

            let setup1 = try await makeSetup(id: "cpsect_s1", courseID: courseID, withNotebook: false)
            let setup2 = try await makeSetup(id: "cpsect_s2", courseID: courseID, withNotebook: false)

            let a1 = APIAssignment(
                testSetupID: try #require(setup1.id), title: "Browser Lab",
                visibility: .closed, sectionID: try browserSec.requireID(),
                courseID: courseID)
            try await a1.save(on: app.db)
            let a2 = APIAssignment(
                testSetupID: try #require(setup2.id), title: "Worker Lab",
                visibility: .closed, sectionID: try workerSec.requireID(),
                courseID: courseID)
            try await a2.save(on: app.db)

            let (boundCookie, token) = try await csrfCookieAndToken(cookie)
            try await app.asyncTest(
                .POST, "/admin/courses/\(courseID.uuidString)/copy",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let copied = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "CPSECT-COPY").first(),
                "Copied course not found")
            let copiedID = try copied.requireID()

            // Sections should be recreated with matching names, in order.
            let copiedSections = try await APICourseSection.query(on: app.db)
                .filter(\.$courseID == copiedID)
                .sort(\.$sortOrder)
                .all()
            #expect(copiedSections.count == 2, "Copy should have 2 sections")
            #expect(copiedSections.first?.name == "Browser Labs")
            #expect(copiedSections.last?.name == "Worker Labs")

            // Every copied assignment should land in the right new section.
            let copiedAssignments = try await APIAssignment.query(on: app.db)
                .filter(\.$courseID == copiedID)
                .all()
            #expect(copiedAssignments.count == 2)
            #expect(
                copiedAssignments.allSatisfy { $0.sectionID != nil },
                "All copied assignments should have a sectionID")

            let copiedBrowserSec = try #require(
                copiedSections.first(where: { $0.name == "Browser Labs" }))
            let browserLab = try #require(
                copiedAssignments.first(where: { $0.title == "Browser Lab" }))
            #expect(browserLab.sectionID == (try copiedBrowserSec.requireID()))

            let copiedWorkerSec = try #require(
                copiedSections.first(where: { $0.name == "Worker Labs" }))
            let workerLab = try #require(
                copiedAssignments.first(where: { $0.title == "Worker Lab" }))
            #expect(workerLab.sectionID == (try copiedWorkerSec.requireID()))
        }
    }

    @Test func courseCopyNotebookPathIsPreserved() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let course = try await makeCourse(code: "CPNB")
            let courseID = try course.requireID()

            // Store the notebook in the new-style subdirectory
            // (notebooks/<id>/<filename>.ipynb), not the legacy flat path —
            // this is the path the old copy code couldn't find.
            let setupID = "cpnb_s1"
            let zipPath = app.testSetupsDirectory + "\(setupID).zip"
            let nbDir = app.testSetupsDirectory + "notebooks/\(setupID)/"
            let nbPath = nbDir + "assignment.ipynb"
            try FileManager.default.createDirectory(atPath: nbDir, withIntermediateDirectories: true)
            try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
                .write(to: URL(fileURLWithPath: zipPath))
            try #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#
                .write(to: URL(fileURLWithPath: nbPath), atomically: true, encoding: .utf8)

            let manifest = """
                {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
                """
            let setup = APITestSetup(
                id: setupID, manifest: manifest, zipPath: zipPath,
                notebookPath: nbPath, courseID: courseID)
            try await setup.save(on: app.db)
            try await makeAssignment(testSetupID: setupID, courseID: courseID)

            let (boundCookie, token) = try await csrfCookieAndToken(cookie)
            try await app.asyncTest(
                .POST, "/admin/courses/\(courseID.uuidString)/copy",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let copied = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "CPNB-COPY").first(),
                "Copied course not found")
            let copiedCourseID = try copied.requireID()

            let copiedSetup = try #require(
                try await APITestSetup.query(on: app.db)
                    .filter(\.$courseID == copiedCourseID)
                    .first())
            let path = try #require(
                copiedSetup.notebookPath, "Copied setup should have a notebookPath set")
            #expect(
                FileManager.default.fileExists(atPath: path),
                "Notebook file should exist on disk at the copied path")
        }
    }
}
