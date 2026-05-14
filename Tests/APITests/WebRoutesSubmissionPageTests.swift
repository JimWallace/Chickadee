// Tests/APITests/WebRoutesSubmissionPageTests.swift
//
// Split from WebRoutesTests.swift.  See WebRoutesTestCase.swift for
// shared helpers (auth, seeding, submitMultipartBody, submitOnceAs).

import Core
import Fluent
import Foundation
import XCTVapor
import XCTest

@testable import chickadee_server

final class WebRoutesSubmissionPageTests: WebRoutesTestCase {

    func testSubmissionPageRendersWarnings() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        try await enrollUser(user)
        _ = try await insertSetup(id: "setup_warn_html")
        _ = try await insertAssignment(testSetupID: "setup_warn_html", title: "Warnings", isOpen: true)
        try await insertSubmission(
            id: "sub_warn_html",
            testSetupID: "setup_warn_html",
            userID: try user.requireID(),
            filename: "submission.py"
        )
        try await insertResult(
            submissionID: "sub_warn_html",
            outcomes: [makeOutcome(name: "test_alpha", status: .pass)],
            warnings: ["Notebook submission.py was normalized before grading."]
        )

        try await app.asyncTest(
            .GET, "/submissions/sub_warn_html",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = String(buffer: res.body)
                XCTAssertTrue(html.contains("Warnings"))
                XCTAssertTrue(html.contains("normalized before grading"))
            })
    }
    // MARK: - GET /submissions/:id (result page)

    func testSubmissionPageShowsPendingState() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await insertSetup(id: "setup_pend")
        try await insertSubmission(id: "sub_pend", testSetupID: "setup_pend", userID: userID, status: "pending")

        try await app.asyncTest(
            .GET, "/submissions/sub_pend",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertTrue(
                    html.contains("pending") || html.contains("Pending"),
                    "Should indicate pending status")
            })
    }

    func testSubmissionPageShowsResults() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await insertSetup(id: "setup_res")
        try await insertSubmission(id: "sub_res", testSetupID: "setup_res", userID: userID)
        try await insertResult(
            submissionID: "sub_res",
            outcomes: [
                makeOutcome(name: "test_add", status: .pass),
                makeOutcome(name: "test_sub", status: .fail),
            ])

        try await app.asyncTest(
            .GET, "/submissions/sub_res",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertTrue(html.contains("test_add"), "Should show test name")
                XCTAssertTrue(html.contains("Pass") || html.contains("pass"), "Should show pass status")
                XCTAssertTrue(html.contains("Fail") || html.contains("fail"), "Should show fail status")
            })
    }

    func testSubmissionPageShowsExpandedOutputPanelForFailingTests() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await insertSetup(id: "setup_fail_output")
        try await insertSubmission(id: "sub_fail_output", testSetupID: "setup_fail_output", userID: userID)
        try await insertResult(
            submissionID: "sub_fail_output",
            outcomes: [
                makeOutcome(
                    name: "test_failure", status: .fail, shortResult: "Expected 42, got 0",
                    longResult: "Traceback line 1\nTraceback line 2")
            ])

        try await app.asyncTest(
            .GET, "/submissions/sub_fail_output",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertFalse(html.contains("<th>Output</th>"))
                XCTAssertTrue(html.contains("test-short-result"))
                XCTAssertTrue(html.contains("Expected 42, got 0"))
                XCTAssertTrue(html.contains("test-output-panel"))
                XCTAssertTrue(html.contains("Traceback line 1"))
            })
    }

    func testSubmissionPageKeepsPassingOutputCollapsedWhenPresent() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await insertSetup(id: "setup_pass_output")
        try await insertSubmission(id: "sub_pass_output", testSetupID: "setup_pass_output", userID: userID)
        try await insertResult(
            submissionID: "sub_pass_output",
            outcomes: [
                makeOutcome(name: "test_pass_with_output", status: .pass, longResult: "stdout:\nAll checks passed")
            ])

        try await app.asyncTest(
            .GET, "/submissions/sub_pass_output",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertTrue(html.contains("Show output"))
                XCTAssertTrue(html.contains("All checks passed"))
                XCTAssertFalse(html.contains("<tr class=\"test-output-row"))
            })
    }

    func testSubmissionPageShowsConfiguredDisplayNameForBrowserResultScriptFilename() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        let manifest = """
            {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[{"tier":"public","script":"test_q1_bmi.py","name":"BMI check"}],"timeLimitSeconds":10}
            """
        let course = try await makeCourse()
        let courseID = try course.requireID()
        let setup = APITestSetup(
            id: "setup_browser_names",
            manifest: manifest,
            zipPath: app.testSetupsDirectory + "setup_browser_names.zip",
            courseID: courseID
        )
        try await setup.save(on: app.db)
        try await insertAssignment(testSetupID: "setup_browser_names", title: "Practice Lab", isOpen: true)
        try await insertSubmission(id: "sub_browser_names", testSetupID: "setup_browser_names", userID: userID)
        try await insertResult(
            submissionID: "sub_browser_names",
            outcomes: [makeOutcome(name: "test_q1_bmi.py", status: .pass)],
            source: "browser"
        )

        try await app.asyncTest(
            .GET, "/submissions/sub_browser_names",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertTrue(html.contains("BMI check"), "Should show saved display name")
                XCTAssertFalse(html.contains(">test_q1_bmi.py<"), "Should not fall back to raw script filename")
            })
    }

    func testSubmissionPageShowsTracebackInsteadOfStructuredJSONBlob() async throws {
        let rawJSON = #"""
            {"error":"PythonError","stderr":"Traceback (most recent call last):\n  File \"test_q1.py\", line 7, in <module>\n    assert answer == 42\nAssertionError","headers":{"content-type":"application/json"}}
            """#
        let formatted = formattedDetailedOutput(primary: rawJSON, fallback: nil, status: .fail)
        XCTAssertEqual(
            formatted,
            """
            Traceback (most recent call last):
              File "test_q1.py", line 7, in <module>
                assert answer == 42
            AssertionError
            """
        )

        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await insertSetup(id: "setup_traceback")
        try await insertSubmission(id: "sub_traceback", testSetupID: "setup_traceback", userID: userID)
        try await insertResult(
            submissionID: "sub_traceback",
            outcomes: [makeOutcome(name: "test_q1", status: .fail, longResult: rawJSON)]
        )

        try await app.asyncTest(
            .GET, "/submissions/sub_traceback",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertTrue(html.contains("test-output-panel"))
                XCTAssertTrue(html.contains("Traceback (most recent call last):"))
                XCTAssertTrue(html.contains("AssertionError"))
                XCTAssertFalse(html.contains("test output here"))
            })
    }

    func testSubmissionPageShowsFirstTryPerfectBadge() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await insertSetup(id: "setup_submission_badge")
        try await insertSubmission(
            id: "sub_submission_badge", testSetupID: "setup_submission_badge", userID: userID, attemptNumber: 1)
        try await insertResult(
            submissionID: "sub_submission_badge",
            outcomes: [
                makeOutcome(name: "t1", status: .pass),
                makeOutcome(name: "t2", status: .pass),
            ])

        try await app.asyncTest(
            .GET, "/submissions/sub_submission_badge",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertTrue(html.contains("Ace"))
                XCTAssertTrue(html.contains("achievement-badge"))
            })
    }

    func testSubmissionPageShowsTracebackWhenStructuredJSONIsWrappedInStdout() async throws {
        let wrapped = #"""
            stdout:
            {"shortResult": "Q1: BMI Calculation: Could not test calculate_bmi", "status": "error", "test": "Q1: BMI Calculation", "error": "Could not test calculate_bmi", "exception": "NotImplementedError('Implement calculate_bmi')", "traceback": "Traceback (most recent call last):\n  File \"test_q1_bmi.py\", line 12, in <module>\n    result = fn(*args)\n             ^^^^^^^^^\n  File \"/chickadee_work_1774744743040/submission.py\", line 27, in calculate_bmi\n    raise NotImplementedError(\"Implement calculate_bmi\")\nNotImplementedError: Implement calculate_bmi\n"}
            """#
        let formatted = formattedDetailedOutput(primary: wrapped, fallback: nil, status: .error)
        XCTAssertEqual(
            formatted,
            """
            Traceback (most recent call last):
              File "test_q1_bmi.py", line 12, in <module>
                result = fn(*args)
                         ^^^^^^^^^
              File "/chickadee_work_1774744743040/submission.py", line 27, in calculate_bmi
                raise NotImplementedError("Implement calculate_bmi")
            NotImplementedError: Implement calculate_bmi
            """
        )

        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await insertSetup(id: "setup_stdout_traceback")
        try await insertSubmission(id: "sub_stdout_traceback", testSetupID: "setup_stdout_traceback", userID: userID)
        try await insertResult(
            submissionID: "sub_stdout_traceback",
            outcomes: [makeOutcome(name: "Q1: BMI Calculation", tier: .pub, status: .error, longResult: wrapped)],
            source: "browser"
        )

        try await app.asyncTest(
            .GET, "/submissions/sub_stdout_traceback",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertTrue(html.contains("Traceback (most recent call last):"))
                XCTAssertTrue(html.contains("NotImplementedError: Implement calculate_bmi"))
                XCTAssertFalse(html.contains("\"shortResult\""))
                XCTAssertFalse(html.contains("\"exception\""))
            })
    }

    func testSubmissionPagePrefersStdoutTracebackOverUnhelpfulStderrSection() async throws {
        let wrapped = #"""
            stdout:
            {"shortResult": "Q1: BMI Calculation: Could not test calculate_bmi", "status": "error", "traceback": "Traceback (most recent call last):\n  File \"test_q1_bmi.py\", line 12, in <module>\n    result = fn(*args)\n             ^^^^^^^^^\nNotImplementedError: Implement calculate_bmi\n"}

            stderr:
            Browser runner reported a structured failure payload
            """#
        let formatted = formattedDetailedOutput(primary: wrapped, fallback: nil, status: .error)
        XCTAssertEqual(
            formatted,
            """
            Traceback (most recent call last):
              File "test_q1_bmi.py", line 12, in <module>
                result = fn(*args)
                         ^^^^^^^^^
            NotImplementedError: Implement calculate_bmi
            """
        )
    }

    func testSubmissionPageFormatsStructuredShortResultInsteadOfShowingJSONBlob() async throws {
        let shortJSON = #"""
            {"shortResult":"Q1: BMI Calculation: Could not test calculate_bmi","status":"error","error":"Could not test calculate_bmi","traceback":"Traceback (most recent call last):\n  File \"test_q1_bmi.py\", line 12, in <module>\n    result = fn(*args)\nNotImplementedError: Implement calculate_bmi\n"}
            """#

        XCTAssertEqual(
            formattedShortResult(from: shortJSON, status: .error),
            "Q1: BMI Calculation: Could not test calculate_bmi"
        )
        XCTAssertEqual(
            formattedDetailedOutput(primary: nil, fallback: shortJSON, status: .error),
            """
            Traceback (most recent call last):
              File "test_q1_bmi.py", line 12, in <module>
                result = fn(*args)
            NotImplementedError: Implement calculate_bmi
            """
        )

        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await insertSetup(id: "setup_short_json")
        try await insertSubmission(id: "sub_short_json", testSetupID: "setup_short_json", userID: userID)
        try await insertResult(
            submissionID: "sub_short_json",
            outcomes: [
                TestOutcome(
                    testName: "Q1: BMI Calculation",
                    testClass: nil,
                    tier: .pub,
                    status: .error,
                    shortResult: shortJSON,
                    longResult: nil,
                    executionTimeMs: 10,
                    memoryUsageBytes: nil,
                    attemptNumber: 1,
                    isFirstPassSuccess: false
                )
            ],
            source: "browser"
        )

        try await app.asyncTest(
            .GET, "/submissions/sub_short_json",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertTrue(html.contains("Q1: BMI Calculation: Could not test calculate_bmi"))
                XCTAssertTrue(html.contains("Traceback (most recent call last):"))
                XCTAssertFalse(html.contains("\"shortResult\""))
                XCTAssertFalse(html.contains("\"traceback\""))
            })
    }

    func testStudentCannotViewOtherStudentsSubmission() async throws {
        let cookie = try await loginAsStudent()
        // Create a submission owned by a different user
        let otherUser = APIUser(username: "other", passwordHash: try Bcrypt.hash("pass"), role: "student")
        try await otherUser.save(on: app.db)
        let otherID = try otherUser.requireID()
        try await insertSetup(id: "setup_priv")
        try await insertSubmission(id: "sub_priv", testSetupID: "setup_priv", userID: otherID)

        try await app.asyncTest(
            .GET, "/submissions/sub_priv",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .forbidden)
            })
    }

    func testInstructorCanViewAnySubmission() async throws {
        let cookie = try await loginAsInstructor()
        let student = APIUser(username: "s2", passwordHash: try Bcrypt.hash("pass"), role: "student")
        try await student.save(on: app.db)
        let studentID = try student.requireID()
        try await insertSetup(id: "setup_any")
        try await insertSubmission(id: "sub_any", testSetupID: "setup_any", userID: studentID)

        try await app.asyncTest(
            .GET, "/submissions/sub_any",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
            })
    }

    func testSubmissionPage404ForMissing() async throws {
        let cookie = try await loginAsStudent()

        try await app.asyncTest(
            .GET, "/submissions/nonexistent",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
    }

    // MARK: - Tier visibility

    func testStudentSeesOnlyPublicTiersBeforeDeadline() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await insertSetup(id: "setup_tier")
        // Due date in the future → release tests are hidden
        try await insertAssignment(
            testSetupID: "setup_tier", title: "Tiered", isOpen: true,
            dueAt: Date().addingTimeInterval(86400 * 30)
        )
        try await insertSubmission(id: "sub_tier", testSetupID: "setup_tier", userID: userID)
        try await insertResult(
            submissionID: "sub_tier",
            outcomes: [
                makeOutcome(name: "pub_test", tier: .pub, status: .pass),
                makeOutcome(name: "rel_test", tier: .release, status: .fail),
                makeOutcome(name: "sec_test", tier: .secret, status: .pass),
            ])

        try await app.asyncTest(
            .GET, "/submissions/sub_tier",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertTrue(html.contains("pub_test"), "Public test should be visible")
                XCTAssertFalse(html.contains("rel_test"), "Release test name should be hidden before deadline")
                XCTAssertFalse(html.contains("sec_test"), "Secret test name should never be shown")
            })
    }

    func testStudentSeesReleaseTiersAfterDeadline() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await insertSetup(id: "setup_post")
        // Due date in the past → release tests are visible
        try await insertAssignment(
            testSetupID: "setup_post", title: "Past Due", isOpen: true,
            dueAt: Date().addingTimeInterval(-86400)
        )
        try await insertSubmission(id: "sub_post", testSetupID: "setup_post", userID: userID)
        try await insertResult(
            submissionID: "sub_post",
            outcomes: [
                makeOutcome(name: "pub_test2", tier: .pub, status: .pass),
                makeOutcome(name: "rel_test2", tier: .release, status: .fail),
            ])

        try await app.asyncTest(
            .GET, "/submissions/sub_post",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertTrue(html.contains("pub_test2"), "Public test should be visible")
                XCTAssertTrue(html.contains("rel_test2"), "Release test should be visible after deadline")
            })
    }

    func testStudentCannotViewPeerSubmissionPage() async throws {
        // Student A owns the submission; Student B must be forbidden from viewing it.
        // This exercises the ownership guard in WebRoutes+Submission.swift
        // (submission.userID == user.id check).
        let studentA = APIUser(username: "peer_student_a", passwordHash: try Bcrypt.hash("pass"), role: "student")
        try await studentA.save(on: app.db)
        let studentAID = try studentA.requireID()

        try await insertSetup(id: "setup_peer")
        try await insertSubmission(id: "sub_peer_a", testSetupID: "setup_peer", userID: studentAID)

        // Log in as a different student and attempt to access Student A's submission.
        let cookieB = try await loginUser(username: "peer_student_b", password: "pass", role: "student", on: app)

        try await app.asyncTest(
            .GET, "/submissions/sub_peer_a",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookieB)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .forbidden, "Student B must not view Student A's submission")
            })
    }

    func testInstructorSeesAllTiers() async throws {
        let cookie = try await loginAsInstructor()
        let student = APIUser(username: "s3", passwordHash: try Bcrypt.hash("pass"), role: "student")
        try await student.save(on: app.db)
        let studentID = try student.requireID()
        try await insertSetup(id: "setup_all")
        try await insertAssignment(
            testSetupID: "setup_all", title: "All Tiers", isOpen: true,
            dueAt: Date().addingTimeInterval(86400 * 30)
        )
        try await insertSubmission(id: "sub_all", testSetupID: "setup_all", userID: studentID)
        try await insertResult(
            submissionID: "sub_all",
            outcomes: [
                makeOutcome(name: "pub_t", tier: .pub, status: .pass),
                makeOutcome(name: "rel_t", tier: .release, status: .fail),
                makeOutcome(name: "sec_t", tier: .secret, status: .pass),
            ])

        try await app.asyncTest(
            .GET, "/submissions/sub_all",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertTrue(html.contains("pub_t"), "Instructor sees public tests")
                XCTAssertTrue(html.contains("rel_t"), "Instructor sees release tests")
                XCTAssertTrue(html.contains("sec_t"), "Instructor sees secret tests")
            })
    }
}
