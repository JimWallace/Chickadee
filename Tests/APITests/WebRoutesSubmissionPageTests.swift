// Tests/APITests/WebRoutesSubmissionPageTests.swift
//
// Split from WebRoutesTests.swift.  See WebRoutesTestCase.swift for
// shared helpers (auth, seeding, submitMultipartBody, submitOnceAs).

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import chickadee_server

@Suite struct WebRoutesSubmissionPageTests {

    // MARK: - Cross-tenant submission gate (issue #551)

    @Test func studentCannotSubmitToAssignmentInForeignCourse() async throws {
        try await withWebRoutesApp { app in
            // requireOpenStudentAssignment must reject submissions to a setup
            // whose course the caller isn't enrolled in.  Without the check, a
            // student in CS101 who learns a testSetupID for a different course
            // can submit there and pollute the foreign instructor's queue.
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            try await wrEnrollUser(user, on: app)  // Enrolls in CS101 only.

            let foreignCourse = APICourse(code: "OTHER101", name: "Other Course")
            try await foreignCourse.save(on: app.db)
            let foreignCourseID = try foreignCourse.requireID()

            let foreignSetup = APITestSetup(
                id: "setup_foreign",
                manifest: """
                    {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
                    """,
                zipPath: app.testSetupsDirectory + "setup_foreign.zip",
                courseID: foreignCourseID
            )
            try await foreignSetup.save(on: app.db)
            let foreignAssignment = APIAssignment(
                testSetupID: "setup_foreign",
                title: "Foreign Assignment",
                dueAt: nil,
                isOpen: true,
                courseID: foreignCourseID
            )
            try await foreignAssignment.save(on: app.db)

            // GET should already fail (added to submitForm in the same fix), so
            // pull CSRF from a page the student CAN see.
            let (csrf, sessionCookie) = try await csrfFields(
                for: "/", cookie: cookie, on: app
            )
            let boundary = "xtenant-boundary"
            try await app.asyncTest(
                .POST, "/testsetups/setup_foreign/submit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data",
                        parameters: ["boundary": boundary]
                    )
                    req.body = .init(
                        buffer: wrSubmitMultipartBody(boundary: boundary, csrfToken: csrf)
                    )
                },
                afterResponse: { res in
                    #expect(
                        res.status == .forbidden,
                        "Student not enrolled in foreign course must get 403; got \(res.status)")
                })

        }
    }

    @Test func studentCannotGetSubmitPageForForeignCourse() async throws {
        try await withWebRoutesApp { app in
            // GET /testsetups/:id/submit leaked the assignment title and the
            // existence of the setup to any authenticated user.  Same fix as
            // the POST: require course enrollment.
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            try await wrEnrollUser(user, on: app)

            let foreignCourse = APICourse(code: "OTHER202", name: "Other Course 2")
            try await foreignCourse.save(on: app.db)
            let foreignCourseID = try foreignCourse.requireID()
            let foreignSetup = APITestSetup(
                id: "setup_foreign_get",
                manifest: """
                    {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
                    """,
                zipPath: app.testSetupsDirectory + "setup_foreign_get.zip",
                courseID: foreignCourseID
            )
            try await foreignSetup.save(on: app.db)

            try await app.asyncTest(
                .GET, "/testsetups/setup_foreign_get/submit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

        }
    }

    @Test func submissionPageRendersWarnings() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            try await wrEnrollUser(user, on: app)
            _ = try await wrInsertSetup(id: "setup_warn_html", on: app)
            _ = try await wrInsertAssignment(testSetupID: "setup_warn_html", title: "Warnings", isOpen: true, on: app)
            try await wrInsertSubmission(
                id: "sub_warn_html",
                testSetupID: "setup_warn_html",
                userID: try user.requireID(),
                filename: "submission.py", on: app
            )
            try await wrInsertResult(
                submissionID: "sub_warn_html",
                outcomes: [wrMakeOutcome(name: "test_alpha", status: .pass)],
                warnings: ["Notebook submission.py was normalized before grading."], on: app
            )

            try await app.asyncTest(
                .GET, "/submissions/sub_warn_html",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = String(buffer: res.body)
                    #expect(html.contains("Warnings"))
                    #expect(html.contains("normalized before grading"))
                })

        }
    }
    // MARK: - GET /submissions/:id (result page)

    @Test func submissionPageShowsPendingState() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()
            try await wrInsertSetup(id: "setup_pend", on: app)
            try await wrInsertSubmission(
                id: "sub_pend", testSetupID: "setup_pend", userID: userID, status: "pending", on: app)

            try await app.asyncTest(
                .GET, "/submissions/sub_pend",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(
                        html.contains("pending") || html.contains("Pending"),
                        "Should indicate pending status")
                })

        }
    }

    @Test func submissionPageShowsResults() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()
            try await wrInsertSetup(id: "setup_res", on: app)
            try await wrInsertSubmission(id: "sub_res", testSetupID: "setup_res", userID: userID, on: app)
            try await wrInsertResult(
                submissionID: "sub_res",
                outcomes: [
                    wrMakeOutcome(name: "test_add", status: .pass),
                    wrMakeOutcome(name: "test_sub", status: .fail),
                ], on: app)

            try await app.asyncTest(
                .GET, "/submissions/sub_res",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("test_add"), "Should show test name")
                    #expect(html.contains("Pass") || html.contains("pass"), "Should show pass status")
                    #expect(html.contains("Fail") || html.contains("fail"), "Should show fail status")
                })

        }
    }

    @Test func submissionPageShowsExpandedOutputPanelForFailingTests() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()
            try await wrInsertSetup(id: "setup_fail_output", on: app)
            try await wrInsertSubmission(
                id: "sub_fail_output", testSetupID: "setup_fail_output", userID: userID, on: app)
            try await wrInsertResult(
                submissionID: "sub_fail_output",
                outcomes: [
                    wrMakeOutcome(
                        name: "test_failure", status: .fail, shortResult: "Expected 42, got 0",
                        longResult: "Traceback line 1\nTraceback line 2")
                ], on: app)

            try await app.asyncTest(
                .GET, "/submissions/sub_fail_output",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("<th>Output</th>") == false)
                    #expect(html.contains("test-short-result"))
                    #expect(html.contains("Expected 42, got 0"))
                    #expect(html.contains("test-output-panel"))
                    #expect(html.contains("Traceback line 1"))
                })

        }
    }

    @Test func submissionPageKeepsPassingOutputCollapsedWhenPresent() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()
            try await wrInsertSetup(id: "setup_pass_output", on: app)
            try await wrInsertSubmission(
                id: "sub_pass_output", testSetupID: "setup_pass_output", userID: userID, on: app)
            try await wrInsertResult(
                submissionID: "sub_pass_output",
                outcomes: [
                    wrMakeOutcome(
                        name: "test_pass_with_output", status: .pass, longResult: "stdout:\nAll checks passed")
                ], on: app)

            try await app.asyncTest(
                .GET, "/submissions/sub_pass_output",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Show output"))
                    #expect(html.contains("All checks passed"))
                    #expect(html.contains("<tr class=\"test-output-row") == false)
                })

        }
    }

    @Test func submissionPageShowsConfiguredDisplayNameForBrowserResultScriptFilename() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()
            let manifest = """
                {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[{"tier":"public","script":"test_q1_bmi.py","name":"BMI check"}],"timeLimitSeconds":10}
                """
            let course = try await wrMakeCourse(on: app)
            let courseID = try course.requireID()
            let setup = APITestSetup(
                id: "setup_browser_names",
                manifest: manifest,
                zipPath: app.testSetupsDirectory + "setup_browser_names.zip",
                courseID: courseID
            )
            try await setup.save(on: app.db)
            try await wrInsertAssignment(
                testSetupID: "setup_browser_names", title: "Practice Lab", isOpen: true, on: app)
            try await wrInsertSubmission(
                id: "sub_browser_names", testSetupID: "setup_browser_names", userID: userID, on: app)
            try await wrInsertResult(
                submissionID: "sub_browser_names",
                outcomes: [wrMakeOutcome(name: "test_q1_bmi.py", status: .pass)],
                source: "browser", on: app
            )

            try await app.asyncTest(
                .GET, "/submissions/sub_browser_names",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("BMI check"), "Should show saved display name")
                    #expect(html.contains(">test_q1_bmi.py<") == false, "Should not fall back to raw script filename")
                })

        }
    }

    @Test func submissionPageShowsTracebackInsteadOfStructuredJSONBlob() async throws {
        try await withWebRoutesApp { app in
            let rawJSON = #"""
                {"error":"PythonError","stderr":"Traceback (most recent call last):\n  File \"test_q1.py\", line 7, in <module>\n    assert answer == 42\nAssertionError","headers":{"content-type":"application/json"}}
                """#
            let formatted = formattedDetailedOutput(primary: rawJSON, fallback: nil, status: .fail)
            #expect(
                formatted == """
                    Traceback (most recent call last):
                      File "test_q1.py", line 7, in <module>
                        assert answer == 42
                    AssertionError
                    """)

            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()
            try await wrInsertSetup(id: "setup_traceback", on: app)
            try await wrInsertSubmission(id: "sub_traceback", testSetupID: "setup_traceback", userID: userID, on: app)
            try await wrInsertResult(
                submissionID: "sub_traceback",
                outcomes: [wrMakeOutcome(name: "test_q1", status: .fail, longResult: rawJSON)], on: app
            )

            try await app.asyncTest(
                .GET, "/submissions/sub_traceback",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("test-output-panel"))
                    #expect(html.contains("Traceback (most recent call last):"))
                    #expect(html.contains("AssertionError"))
                    #expect(html.contains("test output here") == false)
                })

        }
    }

    @Test func submissionPageShowsFirstTryPerfectBadge() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()
            try await wrInsertSetup(id: "setup_submission_badge", on: app)
            try await wrInsertSubmission(
                id: "sub_submission_badge", testSetupID: "setup_submission_badge", userID: userID, attemptNumber: 1,
                on: app)
            try await wrInsertResult(
                submissionID: "sub_submission_badge",
                outcomes: [
                    wrMakeOutcome(name: "t1", status: .pass),
                    wrMakeOutcome(name: "t2", status: .pass),
                ], on: app)

            try await app.asyncTest(
                .GET, "/submissions/sub_submission_badge",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Ace"))
                    #expect(html.contains("achievement-badge"))
                })

        }
    }

    @Test func submissionPageShowsTracebackWhenStructuredJSONIsWrappedInStdout() async throws {
        try await withWebRoutesApp { app in
            let wrapped = #"""
                stdout:
                {"shortResult": "Q1: BMI Calculation: Could not test calculate_bmi", "status": "error", "test": "Q1: BMI Calculation", "error": "Could not test calculate_bmi", "exception": "NotImplementedError('Implement calculate_bmi')", "traceback": "Traceback (most recent call last):\n  File \"test_q1_bmi.py\", line 12, in <module>\n    result = fn(*args)\n             ^^^^^^^^^\n  File \"/chickadee_work_1774744743040/submission.py\", line 27, in calculate_bmi\n    raise NotImplementedError(\"Implement calculate_bmi\")\nNotImplementedError: Implement calculate_bmi\n"}
                """#
            let formatted = formattedDetailedOutput(primary: wrapped, fallback: nil, status: .error)
            #expect(
                formatted == """
                    Traceback (most recent call last):
                      File "test_q1_bmi.py", line 12, in <module>
                        result = fn(*args)
                                 ^^^^^^^^^
                      File "/chickadee_work_1774744743040/submission.py", line 27, in calculate_bmi
                        raise NotImplementedError("Implement calculate_bmi")
                    NotImplementedError: Implement calculate_bmi
                    """)

            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()
            try await wrInsertSetup(id: "setup_stdout_traceback", on: app)
            try await wrInsertSubmission(
                id: "sub_stdout_traceback", testSetupID: "setup_stdout_traceback", userID: userID, on: app)
            try await wrInsertResult(
                submissionID: "sub_stdout_traceback",
                outcomes: [wrMakeOutcome(name: "Q1: BMI Calculation", tier: .pub, status: .error, longResult: wrapped)],
                source: "browser", on: app
            )

            try await app.asyncTest(
                .GET, "/submissions/sub_stdout_traceback",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Traceback (most recent call last):"))
                    #expect(html.contains("NotImplementedError: Implement calculate_bmi"))
                    #expect(html.contains("\"shortResult\"") == false)
                    #expect(html.contains("\"exception\"") == false)
                })

        }
    }

    @Test func submissionPagePrefersStdoutTracebackOverUnhelpfulStderrSection() {
        let wrapped = #"""
            stdout:
            {"shortResult": "Q1: BMI Calculation: Could not test calculate_bmi", "status": "error", "traceback": "Traceback (most recent call last):\n  File \"test_q1_bmi.py\", line 12, in <module>\n    result = fn(*args)\n             ^^^^^^^^^\nNotImplementedError: Implement calculate_bmi\n"}

            stderr:
            Browser runner reported a structured failure payload
            """#
        let formatted = formattedDetailedOutput(primary: wrapped, fallback: nil, status: .error)
        #expect(
            formatted == """
                Traceback (most recent call last):
                  File "test_q1_bmi.py", line 12, in <module>
                    result = fn(*args)
                             ^^^^^^^^^
                NotImplementedError: Implement calculate_bmi
                """)
    }

    @Test func submissionPageFormatsStructuredShortResultInsteadOfShowingJSONBlob() async throws {
        try await withWebRoutesApp { app in
            let shortJSON = #"""
                {"shortResult":"Q1: BMI Calculation: Could not test calculate_bmi","status":"error","error":"Could not test calculate_bmi","traceback":"Traceback (most recent call last):\n  File \"test_q1_bmi.py\", line 12, in <module>\n    result = fn(*args)\nNotImplementedError: Implement calculate_bmi\n"}
                """#

            #expect(
                formattedShortResult(from: shortJSON, status: .error)
                    == "Q1: BMI Calculation: Could not test calculate_bmi")
            #expect(
                formattedDetailedOutput(primary: nil, fallback: shortJSON, status: .error) == """
                    Traceback (most recent call last):
                      File "test_q1_bmi.py", line 12, in <module>
                        result = fn(*args)
                    NotImplementedError: Implement calculate_bmi
                    """)

            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()
            try await wrInsertSetup(id: "setup_short_json", on: app)
            try await wrInsertSubmission(id: "sub_short_json", testSetupID: "setup_short_json", userID: userID, on: app)
            try await wrInsertResult(
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
                source: "browser", on: app
            )

            try await app.asyncTest(
                .GET, "/submissions/sub_short_json",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Q1: BMI Calculation: Could not test calculate_bmi"))
                    #expect(html.contains("Traceback (most recent call last):"))
                    #expect(html.contains("\"shortResult\"") == false)
                    #expect(html.contains("\"traceback\"") == false)
                })

        }
    }

    @Test func studentCannotViewOtherStudentsSubmission() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            // Create a submission owned by a different user
            let otherUser = APIUser(username: "other", passwordHash: try Bcrypt.hash("pass"), role: "student")
            try await otherUser.save(on: app.db)
            let otherID = try otherUser.requireID()
            try await wrInsertSetup(id: "setup_priv", on: app)
            try await wrInsertSubmission(id: "sub_priv", testSetupID: "setup_priv", userID: otherID, on: app)

            try await app.asyncTest(
                .GET, "/submissions/sub_priv",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

        }
    }

    @Test func instructorCanViewAnySubmission() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let student = APIUser(username: "s2", passwordHash: try Bcrypt.hash("pass"), role: "student")
            try await student.save(on: app.db)
            let studentID = try student.requireID()
            try await wrInsertSetup(id: "setup_any", on: app)
            try await wrInsertSubmission(id: "sub_any", testSetupID: "setup_any", userID: studentID, on: app)

            try await app.asyncTest(
                .GET, "/submissions/sub_any",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                })

        }
    }

    @Test func submissionPage404ForMissing() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)

            try await app.asyncTest(
                .GET, "/submissions/nonexistent",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    // MARK: - Tier visibility

    @Test func studentSeesOnlyPublicTiersBeforeDeadline() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()
            try await wrInsertSetup(id: "setup_tier", on: app)
            // Due date in the future → release tests are hidden
            try await wrInsertAssignment(
                testSetupID: "setup_tier", title: "Tiered", isOpen: true,
                dueAt: Date().addingTimeInterval(86400 * 30), on: app
            )
            try await wrInsertSubmission(id: "sub_tier", testSetupID: "setup_tier", userID: userID, on: app)
            try await wrInsertResult(
                submissionID: "sub_tier",
                outcomes: [
                    wrMakeOutcome(name: "pub_test", tier: .pub, status: .pass),
                    wrMakeOutcome(name: "rel_test", tier: .release, status: .fail),
                    wrMakeOutcome(name: "sec_test", tier: .secret, status: .pass),
                ], on: app)

            try await app.asyncTest(
                .GET, "/submissions/sub_tier",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("pub_test"), "Public test should be visible")
                    #expect(html.contains("rel_test") == false, "Release test name should be hidden before deadline")
                    #expect(html.contains("sec_test") == false, "Secret test name should never be shown")
                })

        }
    }

    @Test func studentSeesReleaseTiersAfterDeadline() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()
            try await wrInsertSetup(id: "setup_post", on: app)
            // Due date in the past → release tests are visible
            try await wrInsertAssignment(
                testSetupID: "setup_post", title: "Past Due", isOpen: true,
                dueAt: Date().addingTimeInterval(-86400), on: app
            )
            try await wrInsertSubmission(id: "sub_post", testSetupID: "setup_post", userID: userID, on: app)
            try await wrInsertResult(
                submissionID: "sub_post",
                outcomes: [
                    wrMakeOutcome(name: "pub_test2", tier: .pub, status: .pass),
                    wrMakeOutcome(name: "rel_test2", tier: .release, status: .fail),
                ], on: app)

            try await app.asyncTest(
                .GET, "/submissions/sub_post",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("pub_test2"), "Public test should be visible")
                    #expect(html.contains("rel_test2"), "Release test should be visible after deadline")
                })

        }
    }

    @Test func studentCannotViewPeerSubmissionPage() async throws {
        try await withWebRoutesApp { app in
            // Student A owns the submission; Student B must be forbidden from viewing it.
            // This exercises the ownership guard in WebRoutes+Submission.swift
            // (submission.userID == user.id check).
            let studentA = APIUser(username: "peer_student_a", passwordHash: try Bcrypt.hash("pass"), role: "student")
            try await studentA.save(on: app.db)
            let studentAID = try studentA.requireID()

            try await wrInsertSetup(id: "setup_peer", on: app)
            try await wrInsertSubmission(id: "sub_peer_a", testSetupID: "setup_peer", userID: studentAID, on: app)

            // Log in as a different student and attempt to access Student A's submission.
            let cookieB = try await loginUser(username: "peer_student_b", password: "pass", role: "student", on: app)

            try await app.asyncTest(
                .GET, "/submissions/sub_peer_a",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookieB)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden, "Student B must not view Student A's submission")
                })

        }
    }

    @Test func instructorSeesAllTiers() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let student = APIUser(username: "s3", passwordHash: try Bcrypt.hash("pass"), role: "student")
            try await student.save(on: app.db)
            let studentID = try student.requireID()
            try await wrInsertSetup(id: "setup_all", on: app)
            try await wrInsertAssignment(
                testSetupID: "setup_all", title: "All Tiers", isOpen: true,
                dueAt: Date().addingTimeInterval(86400 * 30), on: app
            )
            try await wrInsertSubmission(id: "sub_all", testSetupID: "setup_all", userID: studentID, on: app)
            try await wrInsertResult(
                submissionID: "sub_all",
                outcomes: [
                    wrMakeOutcome(name: "pub_t", tier: .pub, status: .pass),
                    wrMakeOutcome(name: "rel_t", tier: .release, status: .fail),
                    wrMakeOutcome(name: "sec_t", tier: .secret, status: .pass),
                ], on: app)

            try await app.asyncTest(
                .GET, "/submissions/sub_all",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("pub_t"), "Instructor sees public tests")
                    #expect(html.contains("rel_t"), "Instructor sees release tests")
                    #expect(html.contains("sec_t"), "Instructor sees secret tests")
                })

        }
    }
}
