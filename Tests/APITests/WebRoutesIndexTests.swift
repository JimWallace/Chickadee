// Tests/APITests/WebRoutesIndexTests.swift
//
// Split from WebRoutesTests.swift.  See WebRoutesHelpers.swift for the
// `withWebRoutesApp` lifecycle wrapper and free-function helpers.

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import chickadee_server

@Suite struct WebRoutesIndexTests {

    // MARK: - GET / (index page)

    @Test func indexRedirectsToEnrollWhenNotEnrolled() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            // Create two courses so auto-enroll (single-course shortcut) doesn't kick in.
            _ = try await wrMakeCourse(on: app)
            let c2 = APICourse(code: "CS102", name: "Algorithms")
            try await c2.save(on: app.db)

            try await app.asyncTest(
                .GET, "/",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("/enroll") ?? false)
                })
        }
    }

    @Test func indexRendersWhenNoCourses() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)

            try await app.asyncTest(
                .GET, "/",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                })
        }
    }

    @Test func indexShowsOpenAssignmentForStudent() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            try await wrEnrollUser(user, on: app)
            try await wrInsertSetup(id: "setup_vis", on: app)
            try await wrInsertAssignment(testSetupID: "setup_vis", title: "Visible Assignment", isOpen: true, on: app)

            try await app.asyncTest(
                .GET, "/",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Visible Assignment"), "Should show open assignment title")
                })
        }
    }

    @Test func indexShowsBrowserEditActionBeforeStudentHasAnyNotebookWork() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            try await wrEnrollUser(user, on: app)

            let setupID = "setup_browser_first_open"
            let course = try await wrMakeCourse(on: app)
            let courseID = try course.requireID()
            let notebookPath = app.testSetupsDirectory + "\(setupID).ipynb"
            let notebookJSON = """
                {"cells":[{"cell_type":"markdown","metadata":{},"source":["Browser starter"]}],"metadata":{"kernelspec":{"display_name":"Python 3","language":"python","name":"python3"},"language_info":{"name":"python"}},"nbformat":4,"nbformat_minor":5}
                """
            try Data(notebookJSON.utf8).write(to: URL(fileURLWithPath: notebookPath))

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
            try await wrInsertAssignment(testSetupID: setupID, title: "Browser Lab", isOpen: true, on: app)

            try await app.asyncTest(
                .GET, "/",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Browser Lab"))
                    #expect(
                        html.contains("/CS101/browser-lab"),
                        "Browser-graded assignments should expose the notebook action even before any student edits"
                    )
                })
        }
    }

    @Test func indexHidesUnpublishedSetupsFromStudent() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            try await wrEnrollUser(user, on: app)
            try await wrInsertSetup(id: "setup_hidden", on: app)
            // No assignment created → unpublished

            try await app.asyncTest(
                .GET, "/",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(!html.contains("setup_hidden"), "Unpublished setup should be hidden from students")
                })
        }
    }

    @Test func indexShowsAllSetupsForInstructor() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first()
            )
            try await wrEnrollUser(instructor, on: app)
            try await wrInsertSetup(id: "setup_unpub", on: app)

            try await app.asyncTest(
                .GET, "/",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    // Unpublished setups appear in links (e.g. /testsetups/setup_unpub/submit)
                    // and show "unpublished" status badge.
                    #expect(html.contains("unpublished"), "Instructor should see unpublished status")
                })
        }
    }

    @Test func indexShowsBestGrade() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()
            try await wrEnrollUser(user, on: app)
            try await wrInsertSetup(id: "setup_grade", on: app)
            try await wrInsertAssignment(testSetupID: "setup_grade", title: "Graded", isOpen: true, on: app)
            try await wrInsertSubmission(id: "sub_g1", testSetupID: "setup_grade", userID: userID, on: app)
            // 4 out of 5 pass = 80%
            try await wrInsertResult(
                submissionID: "sub_g1",
                outcomes: [
                    wrMakeOutcome(name: "t1", status: .pass),
                    wrMakeOutcome(name: "t2", status: .pass),
                    wrMakeOutcome(name: "t3", status: .pass),
                    wrMakeOutcome(name: "t4", status: .pass),
                    wrMakeOutcome(name: "t5", status: .fail),
                ],
                on: app)

            try await app.asyncTest(
                .GET, "/",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("80%"), "Should show best grade of 80%")
                })
        }
    }

    @Test func indexShowsFirstTryPerfectBadgeForLatestPerfectFirstSubmission() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()
            try await wrEnrollUser(user, on: app)
            try await wrInsertSetup(id: "setup_badge_latest", on: app)
            try await wrInsertAssignment(testSetupID: "setup_badge_latest", title: "Badge Lab", isOpen: true, on: app)
            try await wrInsertSubmission(
                id: "sub_badge_latest", testSetupID: "setup_badge_latest", userID: userID, attemptNumber: 1, on: app)
            try await wrInsertResult(
                submissionID: "sub_badge_latest",
                outcomes: [
                    wrMakeOutcome(name: "t1", status: .pass),
                    wrMakeOutcome(name: "t2", status: .pass),
                ],
                on: app)

            try await app.asyncTest(
                .GET, "/",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("Ace"))
                })
        }
    }

    @Test func indexDoesNotShowFirstTryPerfectBadgeForSecondAttemptPerfectSubmission() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()
            try await wrEnrollUser(user, on: app)
            try await wrInsertSetup(id: "setup_badge_attempt2", on: app)
            try await wrInsertAssignment(testSetupID: "setup_badge_attempt2", title: "Retry Lab", isOpen: true, on: app)
            try await wrInsertSubmission(
                id: "sub_badge_attempt2", testSetupID: "setup_badge_attempt2", userID: userID, attemptNumber: 2, on: app
            )
            try await wrInsertResult(
                submissionID: "sub_badge_attempt2",
                outcomes: [
                    wrMakeOutcome(name: "t1", status: .pass),
                    wrMakeOutcome(name: "t2", status: .pass),
                ],
                on: app)

            try await app.asyncTest(
                .GET, "/",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(!res.body.string.contains("First-Try Perfect"))
                })
        }
    }

    @Test func indexDoesNotShowFirstTryPerfectBadgeForImperfectFirstSubmission() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()
            try await wrEnrollUser(user, on: app)
            try await wrInsertSetup(id: "setup_badge_notperfect", on: app)
            try await wrInsertAssignment(
                testSetupID: "setup_badge_notperfect", title: "Almost Lab", isOpen: true, on: app)
            try await wrInsertSubmission(
                id: "sub_badge_notperfect", testSetupID: "setup_badge_notperfect", userID: userID,
                attemptNumber: 1, on: app)
            try await wrInsertResult(
                submissionID: "sub_badge_notperfect",
                outcomes: [
                    wrMakeOutcome(name: "t1", status: .pass),
                    wrMakeOutcome(name: "t2", status: .fail),
                ],
                on: app)

            try await app.asyncTest(
                .GET, "/",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(!res.body.string.contains("First-Try Perfect"))
                })
        }
    }
}
