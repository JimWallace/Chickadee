// Tests/APITests/WebRoutesIndexTests.swift
//
// Split from WebRoutesTests.swift.  See WebRoutesTestCase.swift for
// shared helpers (auth, seeding, submitMultipartBody, submitOnceAs).

import Core
import Fluent
import Foundation
import XCTVapor
import XCTest

@testable import chickadee_server

final class WebRoutesIndexTests: WebRoutesTestCase {

    // MARK: - GET / (index page)

    func testIndexRedirectsToEnrollWhenNotEnrolled() async throws {
        let cookie = try await loginAsStudent()
        // Create two courses so auto-enroll (single-course shortcut) doesn't kick in.
        _ = try await makeCourse()
        let c2 = APICourse(code: "CS102", name: "Algorithms")
        try await c2.save(on: app.db)

        try await app.asyncTest(
            .GET, "/",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertTrue(res.headers.first(name: .location)?.contains("/enroll") ?? false)
            })
    }

    func testIndexRendersWhenNoCourses() async throws {
        let cookie = try await loginAsStudent()

        try await app.asyncTest(
            .GET, "/",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
            })
    }

    func testIndexShowsOpenAssignmentForStudent() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        try await enrollUser(user)
        try await insertSetup(id: "setup_vis")
        try await insertAssignment(testSetupID: "setup_vis", title: "Visible Assignment", isOpen: true)

        try await app.asyncTest(
            .GET, "/",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertTrue(html.contains("Visible Assignment"), "Should show open assignment title")
            })
    }

    func testIndexShowsBrowserEditActionBeforeStudentHasAnyNotebookWork() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        try await enrollUser(user)

        let setupID = "setup_browser_first_open"
        let course = try await makeCourse()
        let courseID = try course.requireID()
        let notebookPath = app.testSetupsDirectory + "\(setupID).ipynb"
        let notebookJSON = """
            {"cells":[{"cell_type":"markdown","metadata":{},"source":["Browser starter"]}],"metadata":{"kernelspec":{"display_name":"Python 3","language":"python","name":"python3"},"language_info":{"name":"python"}},"nbformat":4,"nbformat_minor":5}
            """
        try notebookJSON.data(using: .utf8)!.write(to: URL(fileURLWithPath: notebookPath))

        let manifest = """
            {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[{"tier":"public","script":"test_browser.py"}],"timeLimitSeconds":10}
            """
        let setup = APITestSetup(
            id: setupID,
            manifest: manifest,
            zipPath: app.testSetupsDirectory + "\(setupID).zip",
            notebookPath: notebookPath,
            courseID: courseID
        )
        try await setup.save(on: app.db)
        try await insertAssignment(testSetupID: setupID, title: "Browser Lab", isOpen: true)

        try await app.asyncTest(
            .GET, "/",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertTrue(html.contains("Browser Lab"))
                XCTAssertTrue(
                    html.contains("/CS101/browser-lab"),
                    "Browser-graded assignments should expose the notebook action even before any student edits"
                )
            })
    }

    func testIndexHidesUnpublishedSetupsFromStudent() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        try await enrollUser(user)
        try await insertSetup(id: "setup_hidden")
        // No assignment created → unpublished

        try await app.asyncTest(
            .GET, "/",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertFalse(html.contains("setup_hidden"), "Unpublished setup should be hidden from students")
            })
    }

    func testIndexShowsAllSetupsForInstructor() async throws {
        let cookie = try await loginAsInstructor()
        let instructor = try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first()!
        try await enrollUser(instructor)
        try await insertSetup(id: "setup_unpub")

        try await app.asyncTest(
            .GET, "/",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                // Unpublished setups appear in links (e.g. /testsetups/setup_unpub/submit)
                // and show "unpublished" status badge.
                XCTAssertTrue(html.contains("unpublished"), "Instructor should see unpublished status")
            })
    }

    func testIndexShowsBestGrade() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await enrollUser(user)
        try await insertSetup(id: "setup_grade")
        try await insertAssignment(testSetupID: "setup_grade", title: "Graded", isOpen: true)
        try await insertSubmission(id: "sub_g1", testSetupID: "setup_grade", userID: userID)
        // 4 out of 5 pass = 80%
        try await insertResult(
            submissionID: "sub_g1",
            outcomes: [
                makeOutcome(name: "t1", status: .pass),
                makeOutcome(name: "t2", status: .pass),
                makeOutcome(name: "t3", status: .pass),
                makeOutcome(name: "t4", status: .pass),
                makeOutcome(name: "t5", status: .fail),
            ])

        try await app.asyncTest(
            .GET, "/",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertTrue(html.contains("80%"), "Should show best grade of 80%")
            })
    }

    func testIndexShowsFirstTryPerfectBadgeForLatestPerfectFirstSubmission() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await enrollUser(user)
        try await insertSetup(id: "setup_badge_latest")
        try await insertAssignment(testSetupID: "setup_badge_latest", title: "Badge Lab", isOpen: true)
        try await insertSubmission(
            id: "sub_badge_latest", testSetupID: "setup_badge_latest", userID: userID, attemptNumber: 1)
        try await insertResult(
            submissionID: "sub_badge_latest",
            outcomes: [
                makeOutcome(name: "t1", status: .pass),
                makeOutcome(name: "t2", status: .pass),
            ])

        try await app.asyncTest(
            .GET, "/",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(res.body.string.contains("Ace"))
            })
    }

    func testIndexDoesNotShowFirstTryPerfectBadgeForSecondAttemptPerfectSubmission() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await enrollUser(user)
        try await insertSetup(id: "setup_badge_attempt2")
        try await insertAssignment(testSetupID: "setup_badge_attempt2", title: "Retry Lab", isOpen: true)
        try await insertSubmission(
            id: "sub_badge_attempt2", testSetupID: "setup_badge_attempt2", userID: userID, attemptNumber: 2)
        try await insertResult(
            submissionID: "sub_badge_attempt2",
            outcomes: [
                makeOutcome(name: "t1", status: .pass),
                makeOutcome(name: "t2", status: .pass),
            ])

        try await app.asyncTest(
            .GET, "/",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertFalse(res.body.string.contains("First-Try Perfect"))
            })
    }

    func testIndexDoesNotShowFirstTryPerfectBadgeForImperfectFirstSubmission() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await enrollUser(user)
        try await insertSetup(id: "setup_badge_notperfect")
        try await insertAssignment(testSetupID: "setup_badge_notperfect", title: "Almost Lab", isOpen: true)
        try await insertSubmission(
            id: "sub_badge_notperfect", testSetupID: "setup_badge_notperfect", userID: userID, attemptNumber: 1)
        try await insertResult(
            submissionID: "sub_badge_notperfect",
            outcomes: [
                makeOutcome(name: "t1", status: .pass),
                makeOutcome(name: "t2", status: .fail),
            ])

        try await app.asyncTest(
            .GET, "/",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertFalse(res.body.string.contains("First-Try Perfect"))
            })
    }
}
