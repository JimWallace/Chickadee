// Tests/APITests/AssignmentRoutesRetestTests.swift
//
// Split from AssignmentRoutesTests.swift.  See AssignmentRoutesTestCase.swift
// for shared helpers (auth, fixtures, multipart builders, zip + notebook
// staging).

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import chickadee_server

@Suite struct AssignmentRoutesRetestTests {

    // MARK: - POST /instructor/:assignmentID/submissions/:submissionID/retest

    @Test func retestSubmissionRequeuesCompletedSubmission() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "setup_retest", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_retest", title: "Lab Retest", isOpen: true, on: app)
            let assignmentID = assignment.publicID
            let student = try await arInsertStudent(on: app)

            let submission = APISubmission(
                id: "sub_retest_1",
                testSetupID: "setup_retest",
                zipPath: app.submissionsDirectory + "sub_retest_1.zip",
                attemptNumber: 1,
                status: "complete",
                userID: student.id
            )
            submission.workerID = "worker-a"
            submission.assignedAt = Date()
            try await submission.save(on: app.db)

            try await app.asyncTest(
                .POST, "/instructor/\(assignmentID)/submissions/sub_retest_1/retest",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["returnTo": "/instructor/\(assignmentID)/submissions", "_csrf": csrf],
                        as: .urlEncodedForm
                    )
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor/\(assignmentID)/submissions")
                })

            let updated = try await APISubmission.find("sub_retest_1", on: app.db)
            #expect(updated?.status == "pending")
            #expect(updated?.workerID == nil)
            #expect(updated?.assignedAt == nil)

        }
    }

    @Test func retestSubmissionRequiresMatchingAssignmentSetup() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "setup_a", on: app)
            try await arInsertSetup(id: "setup_b", on: app)
            let assignment = try await arInsertAssignment(testSetupID: "setup_a", title: "Lab A", isOpen: true, on: app)
            let assignmentID = assignment.publicID
            let student = try await arInsertStudent(username: "student_other_setup", on: app)

            let submission = APISubmission(
                id: "sub_retest_mismatch",
                testSetupID: "setup_b",
                zipPath: app.submissionsDirectory + "sub_retest_mismatch.zip",
                attemptNumber: 1,
                status: "complete",
                userID: student.id
            )
            try await submission.save(on: app.db)

            try await app.asyncTest(
                .POST, "/instructor/\(assignmentID)/submissions/sub_retest_mismatch/retest",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    // MARK: - POST /instructor/:assignmentID/retest  (v0.4.93 "Retest all")

    /// The "Retest all" button flips every student submission on the
    /// assignment's test setup back to `pending` (so the worker regrades
    /// against the current manifest) and stamps `retestedByUserID` with
    /// the instructor who clicked.  Validation submissions for the same
    /// setup are intentionally excluded — they follow their own
    /// `scheduleValidationAfterSuiteEdit` path.
    @Test func retestAllRequeuesStudentSubmissionsAndSkipsValidation() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "setup_retest_all", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_retest_all", title: "Lab Retest All", isOpen: true, on: app
            )
            let assignmentID = assignment.publicID
            let student = try await arInsertStudent(username: "retest_all_student", on: app)

            // Two student submissions: one complete, one already pending.  The
            // "Retest all" button forces both into pending — the idempotent
            // skip only applies to the auto-save path.
            let subA = APISubmission(
                id: "sub_retest_all_a",
                testSetupID: "setup_retest_all",
                zipPath: app.submissionsDirectory + "sub_retest_all_a.zip",
                attemptNumber: 1,
                status: "complete",
                userID: student.id
            )
            subA.workerID = "worker-x"
            subA.assignedAt = Date()
            try await subA.save(on: app.db)

            let subB = APISubmission(
                id: "sub_retest_all_b",
                testSetupID: "setup_retest_all",
                zipPath: app.submissionsDirectory + "sub_retest_all_b.zip",
                attemptNumber: 2,
                status: "pending",
                userID: student.id
            )
            try await subB.save(on: app.db)

            // A validation submission on the same setup — must be untouched.
            let validation = APISubmission(
                id: "sub_retest_all_validation",
                testSetupID: "setup_retest_all",
                zipPath: app.submissionsDirectory + "sub_retest_all_validation.zip",
                attemptNumber: 1,
                status: "complete",
                userID: nil,
                kind: APISubmission.Kind.validation
            )
            try await validation.save(on: app.db)

            try await app.asyncTest(
                .POST, "/instructor/\(assignmentID)/retest",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let retestedA = try await APISubmission.find("sub_retest_all_a", on: app.db)
            #expect(retestedA?.status == "pending")
            #expect(retestedA?.workerID == nil)
            #expect(retestedA?.assignedAt == nil)
            #expect(retestedA?.retestedAt != nil)
            #expect(retestedA?.retestedByUserID != nil, "Retest must stamp the instructor who clicked the button")

            let retestedB = try await APISubmission.find("sub_retest_all_b", on: app.db)
            #expect(retestedB?.status == "pending")
            #expect(
                retestedB?.retestedAt != nil, "Manual Retest All forces every submission, even already-pending ones")

            let validationAfter = try await APISubmission.find("sub_retest_all_validation", on: app.db)
            #expect(
                validationAfter?.status == "complete", "Validation submissions must be excluded from the retest fan-out"
            )
            #expect(validationAfter?.retestedAt == nil)

            // The fan-out stamps `lastRetestedManifestHash` on the setup so a
            // subsequent cosmetic save won't re-trigger the same work.
            let setupAfter = try await APITestSetup.find("setup_retest_all", on: app.db)
            #expect(setupAfter?.lastRetestedManifestHash != nil)

        }
    }

    /// The retest-all endpoint requires instructor role.  Students/guests
    /// hitting it should get a 403.
    @Test func retestAllRequiresInstructorRole() async throws {
        try await withAssignmentRoutesApp { app in
            try await arInsertSetup(id: "setup_retest_forbidden", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_retest_forbidden", title: "Lab RBAC", isOpen: true, on: app
            )
            let assignmentID = assignment.publicID
            let studentCookie = try await loginUser(
                username: "retest_rbac_student",
                password: "pw",
                role: "student",
                on: app
            )
            let (csrf, sessionCookie) = try await csrfFields(
                for: "/login", cookie: studentCookie, on: app
            )

            try await app.asyncTest(
                .POST, "/instructor/\(assignmentID)/retest",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    // RoleMiddleware short-circuits non-instructors to 403 (or 302
                    // to login depending on the auth config).  Either way, the
                    // submission must not be flipped.
                    #expect(
                        res.status == .forbidden
                            || res.status.code >= 300 && res.status.code < 400,
                        "Expected forbidden/redirect, got \(res.status)")
                })

        }
    }

    /// Regression for v0.4.130 / launch-readiness #4.  Pre-fix, a suite
    /// edit (or save) when no compatible runner was available silently
    /// enqueued a validation submission that would never grade — the
    /// instructor saw `validationStatus = "pending"` indefinitely.  Now
    /// the helper pre-checks runner availability and falls back to a
    /// distinct `"no-runner"` status so the assignments view can show a
    /// specific reason.
    @Test func putSuiteSetsNoRunnerStatusWhenNoCompatibleRunner() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            app.migrations.add(CreateRunnerProfiles())
            app.migrations.add(CreateAssignmentRequirements())
            try await app.autoMigrate()
            let cookie = try await arLoginAsInstructor(on: app)

            let setupID = "setup_no_runner"
            let zipPath = app.testSetupsDirectory + "\(setupID).zip"
            try arMakeZip(at: zipPath, entries: [("test_q1.py", "print('q1')")])
            let manifest = """
                {"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"test_q1.py"}],"timeLimitSeconds":10,"makefile":null}
                """
            let setup = APITestSetup(
                id: setupID, manifest: manifest, zipPath: zipPath,
                notebookPath: app.testSetupsDirectory + "notebooks/\(setupID)/assignment.ipynb",
                courseID: courseID
            )
            try await setup.save(on: app.db)
            let assignment = APIAssignment(
                publicID: "NRN001", testSetupID: setupID,
                title: "No Runner", dueAt: nil, isOpen: false,
                courseID: courseID
            )
            try await assignment.save(on: app.db)

            // Seed a validation submission with a real notebook on disk so
            // `loadExistingSolution` returns data — otherwise
            // `scheduleValidationAfterSuiteEdit` returns early before
            // reaching the runner pre-check.
            let solutionPath = app.submissionsDirectory + "no_runner_solution.ipynb"
            try defaultNotebookData(title: "Solution").write(to: URL(fileURLWithPath: solutionPath))
            let validation = APISubmission(
                id: "sub_no_runner_validation",
                testSetupID: setupID,
                zipPath: solutionPath,
                attemptNumber: 1,
                status: "complete",
                filename: "solution.ipynb",
                userID: nil,
                kind: APISubmission.Kind.validation
            )
            try await validation.save(on: app.db)
            assignment.validationSubmissionID = "sub_no_runner_validation"
            try await assignment.save(on: app.db)

            // Notably: no RunnerProfile rows.  `hasCompatibleValidationRunner`
            // returns false; autostart is disabled in tests; so
            // `ensureCompatibleValidationRunnerAvailability` returns false.

            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/NRN001/edit", cookie: cookie, on: app)
            let body = #"""
                {"items":[
                    {"kind":"script","script":{"script":"test_q1.py","tier":"public","points":1,"displayName":"Q1","dependsOn":[]}}
                ]}
                """#
            try await app.asyncTest(
                .PUT, "/instructor/NRN001/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: body)
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "\(res.body.string)")

                })

            let after = try await APIAssignment.query(on: app.db)
                .filter(\.$publicID == "NRN001")
                .first()
            #expect(
                after?.validationStatus == "no-runner",
                "scheduleValidationAfterSuiteEdit must set 'no-runner' when no compatible runner is available")

            // No new pending validation submission should have been enqueued.
            let pending = try await APISubmission.query(on: app.db)
                .filter(\.$testSetupID == setupID)
                .filter(\.$kind == APISubmission.Kind.validation)
                .filter(\.$status == "pending")
                .count()
            #expect(
                pending == 0,
                "Pre-check must skip the enqueue path when no compatible runner exists; otherwise the row sits forever")

        }
    }

    /// Unit test for the new `loadAssignmentRequirementSpec` helper —
    /// confirms it round-trips a persisted `AssignmentRequirement` row
    /// into an `AssignmentRequirementSpec` and returns nil when no row
    /// exists.
    @Test func loadAssignmentRequirementSpecRoundTripsPersistedRow() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            app.migrations.add(CreateAssignmentRequirements())
            try await app.autoMigrate()

            try await arInsertSetup(id: "setup_load_req", on: app)
            let assignment = APIAssignment(
                testSetupID: "setup_load_req", title: "Load Req",
                dueAt: nil, isOpen: false, courseID: courseID
            )
            try await assignment.save(on: app.db)

            // No row → nil.
            let none = try await loadAssignmentRequirementSpec(assignment: assignment, on: app.db)
            #expect(none == nil)

            // Row → spec with the same fields.
            let spec = AssignmentRequirementSpec(
                requiredPlatform: "linux",
                requiredArchitecture: "x86_64",
                requiredLanguages: [AssignmentLanguageRequirement(language: "python")],
                requiredCapabilities: [RunnerCapability(name: "matplotlib")]
            )
            let row = AssignmentRequirement(assignmentID: try assignment.requireID(), specification: spec)
            try await row.save(on: app.db)

            let loaded = try await loadAssignmentRequirementSpec(assignment: assignment, on: app.db)
            #expect(loaded?.requiredPlatform == "linux")
            #expect(loaded?.requiredArchitecture == "x86_64")
            #expect(loaded?.requiredLanguages.map(\.language) == ["python"])
            #expect(loaded?.requiredCapabilities.map(\.name) == ["matplotlib"])

        }
    }

    @Test func assignmentSubmissionsUsesDisplayNameAndWaterlooTime() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(id: "setup_submissions_display_name", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_submissions_display_name",
                title: "Submission Summary",
                isOpen: true, on: app
            )
            let student = try await arInsertStudent(
                username: "jwallace",
                displayName: "Jim Wallace", on: app
            )
            try await arEnrollStudentInTestCourse(student, on: app)

            let submission = APISubmission(
                id: "sub_display_name",
                testSetupID: "setup_submissions_display_name",
                zipPath: app.submissionsDirectory + "sub_display_name.zip",
                attemptNumber: 1,
                status: "complete",
                filename: "submission.ipynb",
                userID: student.id,
                kind: APISubmission.Kind.student
            )
            try await submission.save(on: app.db)

            let persistedSubmission = try await APISubmission.find("sub_display_name", on: app.db)
            let submittedAt = try #require(persistedSubmission?.submittedAt)

            let expectedDate = {
                let fmt = waterlooDateTimeFormatter()
                fmt.timeStyle = .none
                return fmt.string(from: submittedAt)
            }()
            let expectedClock = {
                let fmt = waterlooDateTimeFormatter()
                fmt.dateStyle = .none
                return fmt.string(from: submittedAt)
                    .replacingOccurrences(of: "\u{202F}", with: " ")
                    .replacingOccurrences(of: "\u{00A0}", with: " ")
            }()

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/submissions",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                        .replacingOccurrences(of: "\u{202F}", with: " ")
                        .replacingOccurrences(of: "\u{00A0}", with: " ")
                    #expect(body.contains(">Wallace<"))
                    #expect(body.contains(">Jim<"))
                    #expect(body.contains(expectedDate))
                    #expect(body.contains(expectedClock), "Expected clock '\(expectedClock)' in body: \(body)")
                })

        }
    }
}
