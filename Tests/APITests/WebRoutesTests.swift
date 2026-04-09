// Tests/APITests/WebRoutesTests.swift
//
// Integration tests for WebRoutes: the student/instructor-facing web UI.
//
//   GET  /                           → index/dashboard
//   GET  /testsetups/:id/submit      → submission form
//   GET  /testsetups/:id/history     → submission history
//   GET  /submissions/:id            → live results

import XCTest
import XCTVapor
@testable import chickadee_server
import Fluent
import Foundation
import Core

final class WebRoutesTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = try await Application.make(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-wrt-\(UUID().uuidString)/")
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

    // MARK: - Auth helpers

    private func loginAsStudent() async throws -> String {
        try await loginUser(username: "student1", password: "pass", role: "student", on: app)
    }

    private func loginAsInstructor() async throws -> String {
        try await loginUser(username: "instructor1", password: "pass", role: "instructor", on: app)
    }

    // MARK: - Seeding helpers

    private func studentUser() async throws -> APIUser {
        try await APIUser.query(on: app.db).filter(\.$username == "student1").first()!
    }

    private func makeCourse() async throws -> APICourse {
        if let existing = try await APICourse.query(on: app.db).filter(\.$code == "CS101").first() {
            return existing
        }
        let course = APICourse(code: "CS101", name: "Intro CS")
        try await course.save(on: app.db)
        return course
    }

    private func enrollUser(_ user: APIUser) async throws {
        let course = try await makeCourse()
        let courseID = try course.requireID()
        let userID = try user.requireID()
        if try await APICourseEnrollment.query(on: app.db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == courseID)
            .first() == nil {
            let enrollment = APICourseEnrollment(userID: userID, courseID: courseID)
            try await enrollment.save(on: app.db)
        }
    }

    @discardableResult
    private func insertSetup(id: String) async throws -> APITestSetup {
        let manifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
        """
        let course = try await makeCourse()
        let courseID = try course.requireID()
        let setup = APITestSetup(id: id, manifest: manifest, zipPath: tmpDir + "testsetups/\(id).zip", courseID: courseID)
        try await setup.save(on: app.db)
        return setup
    }

    @discardableResult
    private func insertAssignment(
        testSetupID: String,
        title: String,
        isOpen: Bool,
        dueAt: Date? = nil
    ) async throws -> APIAssignment {
        let course = try await makeCourse()
        let courseID = try course.requireID()
        let a = APIAssignment(testSetupID: testSetupID, title: title, dueAt: dueAt, isOpen: isOpen, courseID: courseID)
        try await a.save(on: app.db)
        return a
    }

    @discardableResult
    private func insertSubmission(
        id: String,
        testSetupID: String,
        userID: UUID,
        attemptNumber: Int = 1,
        status: String = "complete",
        filename: String? = nil
    ) async throws -> APISubmission {
        let sub = APISubmission(
            id: id,
            testSetupID: testSetupID,
            zipPath: tmpDir + "submissions/\(id).py",
            attemptNumber: attemptNumber,
            status: status,
            filename: filename,
            userID: userID,
            kind: APISubmission.Kind.student
        )
        try await sub.save(on: app.db)
        return sub
    }

    private func makeOutcome(
        name: String,
        tier: TestTier = .pub,
        status: TestStatus = .pass,
        shortResult: String? = nil,
        longResult: String? = nil
    ) -> TestOutcome {
        TestOutcome(
            testName: name,
            testClass: nil,
            tier: tier,
            status: status,
            shortResult: shortResult ?? (status == .pass ? "passed" : "failed"),
            longResult: status == .pass ? longResult : (longResult ?? "test output here"),
            executionTimeMs: 10,
            memoryUsageBytes: nil,
            attemptNumber: 1,
            isFirstPassSuccess: status == .pass
        )
    }

    private func makeCollection(
        submissionID: String,
        outcomes: [TestOutcome] = [],
        warnings: [String] = []
    ) -> TestOutcomeCollection {
        TestOutcomeCollection(
            submissionID: submissionID,
            testSetupID: "setup_001",
            attemptNumber: 1,
            buildStatus: .passed,
            compilerOutput: nil,
            outcomes: outcomes,
            totalTests: outcomes.count,
            passCount: outcomes.filter { $0.status == .pass }.count,
            failCount: outcomes.filter { $0.status == .fail }.count,
            errorCount: outcomes.filter { $0.status == .error }.count,
            timeoutCount: outcomes.filter { $0.status == .timeout }.count,
            executionTimeMs: 100,
            warnings: warnings,
            runnerVersion: "shell-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    @discardableResult
    private func insertResult(
        submissionID: String,
        outcomes: [TestOutcome] = [],
        warnings: [String] = [],
        source: String = "worker"
    ) async throws -> APIResult {
        let collection = makeCollection(submissionID: submissionID, outcomes: outcomes, warnings: warnings)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try String(data: encoder.encode(collection), encoding: .utf8)!
        let result = APIResult(
            id: "res_\(UUID().uuidString.lowercased().prefix(8))",
            submissionID: submissionID,
            collectionJSON: json,
            source: source
        )
        try await result.save(on: app.db)
        return result
    }

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

        try await app.asyncTest(.GET, "/submissions/sub_warn_html", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = String(buffer: res.body)
            XCTAssertTrue(html.contains("Warnings"))
            XCTAssertTrue(html.contains("normalized before grading"))
        })
    }

    // MARK: - GET / (index page)

    func testIndexRedirectsToEnrollWhenNotEnrolled() async throws {
        let cookie = try await loginAsStudent()
        // Create two courses so auto-enroll (single-course shortcut) doesn't kick in.
        _ = try await makeCourse()
        let c2 = APICourse(code: "CS102", name: "Algorithms")
        try await c2.save(on: app.db)

        try await app.asyncTest(.GET, "/", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertTrue(res.headers.first(name: .location)?.contains("/enroll") ?? false)
        })
    }

    func testIndexRendersWhenNoCourses() async throws {
        let cookie = try await loginAsStudent()

        try await app.asyncTest(.GET, "/", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })
    }

    func testIndexShowsOpenAssignmentForStudent() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        try await enrollUser(user)
        try await insertSetup(id: "setup_vis")
        try await insertAssignment(testSetupID: "setup_vis", title: "Visible Assignment", isOpen: true)

        try await app.asyncTest(.GET, "/", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("Visible Assignment"), "Should show open assignment title")
        })
    }

    func testIndexHidesUnpublishedSetupsFromStudent() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        try await enrollUser(user)
        try await insertSetup(id: "setup_hidden")
        // No assignment created → unpublished

        try await app.asyncTest(.GET, "/", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
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

        try await app.asyncTest(.GET, "/", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
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
        try await insertResult(submissionID: "sub_g1", outcomes: [
            makeOutcome(name: "t1", status: .pass),
            makeOutcome(name: "t2", status: .pass),
            makeOutcome(name: "t3", status: .pass),
            makeOutcome(name: "t4", status: .pass),
            makeOutcome(name: "t5", status: .fail),
        ])

        try await app.asyncTest(.GET, "/", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
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
        try await insertSubmission(id: "sub_badge_latest", testSetupID: "setup_badge_latest", userID: userID, attemptNumber: 1)
        try await insertResult(submissionID: "sub_badge_latest", outcomes: [
            makeOutcome(name: "t1", status: .pass),
            makeOutcome(name: "t2", status: .pass),
        ])

        try await app.asyncTest(.GET, "/", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("First-Try Perfect"))
        })
    }

    func testIndexDoesNotShowFirstTryPerfectBadgeForSecondAttemptPerfectSubmission() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await enrollUser(user)
        try await insertSetup(id: "setup_badge_attempt2")
        try await insertAssignment(testSetupID: "setup_badge_attempt2", title: "Retry Lab", isOpen: true)
        try await insertSubmission(id: "sub_badge_attempt2", testSetupID: "setup_badge_attempt2", userID: userID, attemptNumber: 2)
        try await insertResult(submissionID: "sub_badge_attempt2", outcomes: [
            makeOutcome(name: "t1", status: .pass),
            makeOutcome(name: "t2", status: .pass),
        ])

        try await app.asyncTest(.GET, "/", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
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
        try await insertSubmission(id: "sub_badge_notperfect", testSetupID: "setup_badge_notperfect", userID: userID, attemptNumber: 1)
        try await insertResult(submissionID: "sub_badge_notperfect", outcomes: [
            makeOutcome(name: "t1", status: .pass),
            makeOutcome(name: "t2", status: .fail),
        ])

        try await app.asyncTest(.GET, "/", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertFalse(res.body.string.contains("First-Try Perfect"))
        })
    }

    // MARK: - GET /testsetups/:id/submit

    func testSubmitFormRendersForStudent() async throws {
        let cookie = try await loginAsStudent()
        try await insertSetup(id: "setup_sub")

        try await app.asyncTest(.GET, "/testsetups/setup_sub/submit", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })
    }

    func testSubmitForm404ForMissingSetup() async throws {
        let cookie = try await loginAsStudent()

        try await app.asyncTest(.GET, "/testsetups/nonexistent/submit", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    // MARK: - GET /testsetups/:id/history

    func testHistoryShowsSubmissions() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await insertSetup(id: "setup_hist")
        try await insertAssignment(testSetupID: "setup_hist", title: "History Test", isOpen: true)
        try await insertSubmission(id: "sub_h1", testSetupID: "setup_hist", userID: userID, attemptNumber: 1)
        try await insertSubmission(id: "sub_h2", testSetupID: "setup_hist", userID: userID, attemptNumber: 2)

        try await app.asyncTest(.GET, "/testsetups/setup_hist/history", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("History Test"), "Should show assignment title")
        })
    }

    func testHistory404ForMissingSetup() async throws {
        let cookie = try await loginAsStudent()

        try await app.asyncTest(.GET, "/testsetups/nonexistent/history", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    // MARK: - GET /submissions/:id (result page)

    func testSubmissionPageShowsPendingState() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await insertSetup(id: "setup_pend")
        try await insertSubmission(id: "sub_pend", testSetupID: "setup_pend", userID: userID, status: "pending")

        try await app.asyncTest(.GET, "/submissions/sub_pend", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("pending") || html.contains("Pending"),
                          "Should indicate pending status")
        })
    }

    func testSubmissionPageShowsResults() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await insertSetup(id: "setup_res")
        try await insertSubmission(id: "sub_res", testSetupID: "setup_res", userID: userID)
        try await insertResult(submissionID: "sub_res", outcomes: [
            makeOutcome(name: "test_add", status: .pass),
            makeOutcome(name: "test_sub", status: .fail),
        ])

        try await app.asyncTest(.GET, "/submissions/sub_res", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
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
        try await insertResult(submissionID: "sub_fail_output", outcomes: [
            makeOutcome(name: "test_failure", status: .fail, shortResult: "Expected 42, got 0", longResult: "Traceback line 1\nTraceback line 2")
        ])

        try await app.asyncTest(.GET, "/submissions/sub_fail_output", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
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
        try await insertResult(submissionID: "sub_pass_output", outcomes: [
            makeOutcome(name: "test_pass_with_output", status: .pass, longResult: "stdout:\nAll checks passed")
        ])

        try await app.asyncTest(.GET, "/submissions/sub_pass_output", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
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
            zipPath: tmpDir + "testsetups/setup_browser_names.zip",
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

        try await app.asyncTest(.GET, "/submissions/sub_browser_names", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
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

        try await app.asyncTest(.GET, "/submissions/sub_traceback", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
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
        try await insertSubmission(id: "sub_submission_badge", testSetupID: "setup_submission_badge", userID: userID, attemptNumber: 1)
        try await insertResult(submissionID: "sub_submission_badge", outcomes: [
            makeOutcome(name: "t1", status: .pass),
            makeOutcome(name: "t2", status: .pass),
        ])

        try await app.asyncTest(.GET, "/submissions/sub_submission_badge", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("First-Try Perfect"))
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

        try await app.asyncTest(.GET, "/submissions/sub_stdout_traceback", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
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

        try await app.asyncTest(.GET, "/submissions/sub_short_json", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
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

        try await app.asyncTest(.GET, "/submissions/sub_priv", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
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

        try await app.asyncTest(.GET, "/submissions/sub_any", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })
    }

    func testSubmissionPage404ForMissing() async throws {
        let cookie = try await loginAsStudent()

        try await app.asyncTest(.GET, "/submissions/nonexistent", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
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
        try await insertResult(submissionID: "sub_tier", outcomes: [
            makeOutcome(name: "pub_test", tier: .pub, status: .pass),
            makeOutcome(name: "rel_test", tier: .release, status: .fail),
            makeOutcome(name: "sec_test", tier: .secret, status: .pass),
        ])

        try await app.asyncTest(.GET, "/submissions/sub_tier", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
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
        try await insertResult(submissionID: "sub_post", outcomes: [
            makeOutcome(name: "pub_test2", tier: .pub, status: .pass),
            makeOutcome(name: "rel_test2", tier: .release, status: .fail),
        ])

        try await app.asyncTest(.GET, "/submissions/sub_post", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("pub_test2"), "Public test should be visible")
            XCTAssertTrue(html.contains("rel_test2"), "Release test should be visible after deadline")
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
        try await insertResult(submissionID: "sub_all", outcomes: [
            makeOutcome(name: "pub_t", tier: .pub, status: .pass),
            makeOutcome(name: "rel_t", tier: .release, status: .fail),
            makeOutcome(name: "sec_t", tier: .secret, status: .pass),
        ])

        try await app.asyncTest(.GET, "/submissions/sub_all", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("pub_t"), "Instructor sees public tests")
            XCTAssertTrue(html.contains("rel_t"), "Instructor sees release tests")
            XCTAssertTrue(html.contains("sec_t"), "Instructor sees secret tests")
        })
    }
}
