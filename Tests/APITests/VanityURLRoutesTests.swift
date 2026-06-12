// Tests/APITests/VanityURLRoutesTests.swift
//
// Tests for GET /:courseCode/:assignmentSlug vanity URL redirects.

import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite(.serialized) final class VanityURLRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-vanity")
    }

    // MARK: - slugify

    @Test func slugify_stripsSpaces() async throws {
        try await withApp(app) { _ in
            #expect(VanityURLRoutes.slugify("Lab 1") == "lab-1")

        }
    }

    @Test func slugify_stripsSpecialChars() async throws {
        try await withApp(app) { _ in
            #expect(VanityURLRoutes.slugify("Lab 1: Intro") == "lab-1-intro")

        }
    }

    @Test func slugify_lowercases() async throws {
        try await withApp(app) { _ in
            #expect(VanityURLRoutes.slugify("Assignment2") == "assignment2")

        }
    }

    @Test func slugify_handlesHyphensAndSlashes() async throws {
        try await withApp(app) { _ in
            #expect(VanityURLRoutes.slugify("A2 - Sorting/Searching") == "a2-sorting-searching")

        }
    }

    @Test func slugify_emptyString() async throws {
        try await withApp(app) { _ in
            #expect(VanityURLRoutes.slugify("").isEmpty)

        }
    }

    // MARK: - Route helpers

    private func seedCourse(code: String, archived: Bool = false) async throws -> APICourse {
        let course = APICourse(code: code, name: "Course \(code)")
        course.isArchived = archived
        try await course.save(on: app.db)
        return course
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

    /// Enrolls the named user in `courseID`.  Required to exercise the
    /// happy path after the v0.4.171 enrollment gate landed on
    /// `resolveAssignment` (issue #561) — unenrolled users now get 404
    /// from every vanity URL so the routes can't be used to enumerate
    /// the catalogue.
    private func enroll(username: String, courseID: UUID) async throws {
        guard
            let user = try await APIUser.query(on: app.db)
                .filter(\.$username == username).first()
        else {
            XCTFail("Expected user \(username) to exist")
            return
        }
        try await APICourseEnrollment(
            userID: try user.requireID(), courseID: courseID
        ).save(on: app.db)
    }

    // MARK: - Unauthenticated

    @Test func vanityURL_unauthenticated_redirectsToLogin() async throws {
        try await withApp(app) { _ in
            let course = try await seedCourse(code: "HLTH230")
            let courseID = try course.requireID()
            try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1", setupID: "setup_van01")

            try await app.asyncTest(.GET, "/hlth230/lab-1") { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/login")
            }

        }
    }

    // MARK: - Authenticated

    @Test func vanityURL_redirectsToNotebook() async throws {
        try await withApp(app) { _ in
            let course = try await seedCourse(code: "HLTH230")
            let courseID = try course.requireID()
            try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1", setupID: "setup_van02")

            let cookie = try await loginUser(
                username: "vanity_student1", password: "pw",
                role: "student", on: app)
            try await enroll(username: "vanity_student1", courseID: courseID)
            try await app.asyncTest(
                .GET, "/hlth230/lab-1",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/testsetups/setup_van02/notebook")
                })

        }
    }

    @Test func vanityURL_caseInsensitiveCourseCode() async throws {
        try await withApp(app) { _ in
            // Course code stored as "CS246"; URL uses lowercase "cs246".
            let course = try await seedCourse(code: "cs246")
            let courseID = try course.requireID()
            try await seedSetupAndAssignment(courseID: courseID, title: "Assignment 2", setupID: "setup_van03")

            let cookie = try await loginUser(
                username: "vanity_student2", password: "pw",
                role: "student", on: app)
            try await enroll(username: "vanity_student2", courseID: courseID)
            try await app.asyncTest(
                .GET, "/cs246/assignment-2",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/testsetups/setup_van03/notebook")
                })

        }
    }

    @Test func vanityURL_slugStripsSpecialChars() async throws {
        try await withApp(app) { _ in
            let course = try await seedCourse(code: "HLTH230")
            let courseID = try course.requireID()
            // Title "Lab 1: Intro" should match slug "lab-1-intro"
            try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1: Intro", setupID: "setup_van04")

            let cookie = try await loginUser(
                username: "vanity_student3", password: "pw",
                role: "student", on: app)
            try await enroll(username: "vanity_student3", courseID: courseID)
            try await app.asyncTest(
                .GET, "/hlth230/lab-1-intro",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/testsetups/setup_van04/notebook")
                })

        }
    }

    @Test func vanityURL_archivedCourse_returns404() async throws {
        try await withApp(app) { _ in
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
                    #expect(res.status == .notFound)
                })

        }
    }

    @Test func vanityURL_unknownCourse_returns404() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "vanity_student5", password: "pw",
                role: "student", on: app)
            try await app.asyncTest(
                .GET, "/nosuchcourse/lab-1",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    @Test func vanityURL_unknownAssignment_returns404() async throws {
        try await withApp(app) { _ in
            let course = try await seedCourse(code: "HLTH230")
            let courseID = try course.requireID()
            try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1", setupID: "setup_van06")

            let cookie = try await loginUser(
                username: "vanity_student6", password: "pw",
                role: "student", on: app)
            try await enroll(username: "vanity_student6", courseID: courseID)
            try await app.asyncTest(
                .GET, "/hlth230/lab99",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    @Test func vanityURL_activeCourseShadowsArchived() async throws {
        try await withApp(app) { _ in
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
            try await enroll(username: "vanity_student7", courseID: activeID)
            try await app.asyncTest(
                .GET, "/hlth230/lab-1",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/testsetups/setup_van08/notebook")
                })

        }
    }

    @Test func vanityURL_usesPersistedSlugAfterTitleRename() async throws {
        try await withApp(app) { _ in
            let course = try await seedCourse(code: "HLTH230")
            let courseID = try course.requireID()
            let assignment = try await seedSetupAndAssignment(
                courseID: courseID, title: "Lab 1", setupID: "setup_van09")
            assignment.title = "Renamed Lab"
            try await assignment.save(on: app.db)

            let cookie = try await loginUser(
                username: "vanity_student8", password: "pw",
                role: "student", on: app)
            try await enroll(username: "vanity_student8", courseID: courseID)
            try await app.asyncTest(
                .GET, "/hlth230/lab-1",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/testsetups/setup_van09/notebook")
                })

            try await app.asyncTest(
                .GET, "/hlth230/renamed-lab",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    @Test func uniqueAssignmentSlug_suffixesDuplicateTitlesInCourse() async throws {
        try await withApp(app) { _ in
            let course = try await seedCourse(code: "HLTH230")
            let courseID = try course.requireID()
            try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1", setupID: "setup_van10")

            let slug = try await uniqueAssignmentSlug(title: "Lab 1", courseID: courseID, db: app.db)
            #expect(slug == "lab-1-2")

        }
    }

    // MARK: - Enrollment gate (issue #561)

    @Test func vanityURL_unenrolledStudent_returns404() async throws {
        try await withApp(app) { _ in
            // Regression for issue #561: vanity URLs leaked the existence of
            // a (courseCode, assignmentSlug) pair to any authenticated user
            // by redirecting unenrolled students into the access-denied page
            // instead of 404'ing.
            let course = try await seedCourse(code: "HLTH230")
            let courseID = try course.requireID()
            try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1", setupID: "setup_van_enr01")

            let cookie = try await loginUser(
                username: "vanity_outsider", password: "pw",
                role: "student", on: app)
            try await app.asyncTest(
                .GET, "/hlth230/lab-1",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(
                        res.status == .notFound,
                        "Unenrolled student must see 404 (matching no-such-course response), got \(res.status)")
                })

        }
    }

    @Test func vanityURL_instructor_bypassesEnrollment() async throws {
        try await withApp(app) { _ in
            // Instructors and admins skip the enrollment check so they can
            // QA assignments in courses they aren't formally enrolled in.
            let course = try await seedCourse(code: "HLTH230")
            let courseID = try course.requireID()
            try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1", setupID: "setup_van_enr02")

            let cookie = try await loginUser(
                username: "vanity_instructor", password: "pw",
                role: "instructor", on: app)
            try await app.asyncTest(
                .GET, "/hlth230/lab-1",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/testsetups/setup_van_enr02/notebook")
                })

        }
    }

    @Test func vanityURL_submitAndHistoryRoutesRedirectToCanonicalStudentRoutes() async throws {
        try await withApp(app) { _ in
            let course = try await seedCourse(code: "HLTH230")
            let courseID = try course.requireID()
            try await seedSetupAndAssignment(courseID: courseID, title: "Lab 1", setupID: "setup_van11")

            let cookie = try await loginUser(
                username: "vanity_student9", password: "pw",
                role: "student", on: app)
            try await enroll(username: "vanity_student9", courseID: courseID)
            try await app.asyncTest(
                .GET, "/hlth230/lab-1/submit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/testsetups/setup_van11/submit")
                })

            try await app.asyncTest(
                .GET, "/hlth230/lab-1/history",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/testsetups/setup_van11/history")
                })

        }
    }
}
