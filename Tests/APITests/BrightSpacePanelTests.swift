// Tests/APITests/BrightSpacePanelTests.swift
//
// Covers the instructor BrightSpace tab + the sync-log model.  These run
// without a live D2L: in the test app `brightSpaceClient` is nil, so the
// page renders its "not configured" state and the manual-action routes are
// no-op redirects.  The log model is exercised directly against the DB to
// prove the migration + schema.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct BrightSpacePanelTests {

    // MARK: - Access control

    @Test func studentCannotAccessBrightspaceTab() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsStudent(on: app)
            try await app.asyncTest(
                .GET, "/instructor/brightspace",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.status == .forbidden) })
        }
    }

    // MARK: - Page render (sync unconfigured in tests)

    @Test func brightspacePageRendersNotConfigured() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await app.asyncTest(
                .GET, "/instructor/brightspace",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    // The LEARN tab renders; the per-instructor account + org-unit
                    // sections are gone (service-account model only).
                    #expect(html.contains("LEARN"))
                    #expect(!html.contains("Your LEARN account"))
                })
        }
    }

    @Test func brightspacePageRendersDashboardWhenConfigured() async throws {
        try await withAssignmentRoutesApp { app in
            // Configured + active course → the dashboard renders: the
            // Connection panel (#1114 — not yet connected, so the connect form
            // shows), grade-item mapping (+ auto-map), and the export button.
            app.brightSpaceAppCredentials = BrightSpaceAppCredentials(
                baseURL: "https://learn.test", appID: "a", appKey: "k", debounceSecs: 90)
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            try await app.asyncTest(
                .GET, "/instructor/brightspace",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Grade-item mapping"))
                    #expect(html.contains("Export Grades CSV"))
                    #expect(html.contains("Auto-map by name"))
                    #expect(html.contains("Your LEARN account is not connected"))
                    #expect(html.contains("/instructor/brightspace/connect"))
                    // Identity actions require a connected account.
                    #expect(!html.contains("/instructor/brightspace/disconnect"))
                })
        }
    }

    @Test func connectionPanelShowsIdentityActionsWhenConnected() async throws {
        try await withAssignmentRoutesApp { app in
            // A connected instructor sees their identity plus the test /
            // take-over / disconnect / link-course actions instead of the
            // connect form (#1114 — the runbook's per-instructor flow).
            app.brightSpaceAppCredentials = BrightSpaceAppCredentials(
                baseURL: "https://learn.test", appID: "a", appKey: "k", debounceSecs: 90)
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "testinstructor").first())
            try await BrightSpaceCredentialStore.save(
                valenceUserID: "vu", valenceUserKey: "vk", identityName: "Test Instructor (ti)",
                capturedByUserID: instructor.id, userID: instructor.id, on: app.db)

            try await app.asyncTest(
                .GET, "/instructor/brightspace",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Test Instructor (ti)"))
                    #expect(html.contains("Test connection"))
                    #expect(html.contains("/instructor/brightspace/use-my-identity"))
                    #expect(html.contains("/instructor/brightspace/disconnect"))
                    #expect(html.contains("/instructor/brightspace/bind-org-unit"))
                    // Connected → the connect form is gone.
                    #expect(!html.contains("Connect my LEARN account"))
                })
        }
    }

    @Test func readinessPanelRendersUnreachableStudents() async throws {
        try await withAssignmentRoutesApp { app in
            // Configured + linked course with one student persisted as unreachable
            // → the LEARN roster-readiness panel lists them with the reason.
            app.brightSpaceAppCredentials = BrightSpaceAppCredentials(
                baseURL: "https://learn.test", appID: "a", appKey: "k", debounceSecs: 90)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let course = try #require(try await APICourse.find(courseID, on: app.db))
            course.brightspaceOrgUnitID = "999"
            try await course.save(on: app.db)

            let student = try await arInsertStudent(
                username: "unreach_user", displayName: "Una Reachable", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            let enroll = try #require(
                try await APICourseEnrollment.query(on: app.db)
                    .filter(\.$userID == student.requireID()).first())
            enroll.learnSyncReadiness = .unreachable
            enroll.brightspaceSyncDetail = "Not on the LEARN classlist."
            enroll.brightspaceCheckedAt = Date()
            try await enroll.save(on: app.db)

            let cookie = try await arLoginAsInstructor(on: app)
            try await app.asyncTest(
                .GET, "/instructor/brightspace",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Class Roster"))
                    #expect(html.contains("Una Reachable"))
                    #expect(html.contains("Reconcile now"))
                    // The old log-heuristic section is gone.
                    #expect(!html.contains("Unmapped students"))
                })
        }
    }

    @Test func autoMapRedirectsWhenNotConfigured() async throws {
        try await withAssignmentRoutesApp { app in
            // No live D2L in tests → brightSpaceClient is nil, so auto-map can't
            // read the grade book; it should flash + redirect, not crash.
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/instructor/brightspace/auto-map",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                },
                afterResponse: { res in
                    #expect(res.headers.first(name: .location) == "/instructor/brightspace")
                })
        }
    }

    // MARK: - Org-unit binding (instructor self-serve)

    @Test func bindOrgUnitRejectedWhenNotConnected() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/instructor/brightspace/bind-org-unit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    try req.content.encode(["orgUnitID": "1106038"], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.headers.first(name: .location) == "/instructor/brightspace")
                })
            // Not connected → binding is refused, course untouched.
            let course = try #require(try await APICourse.find(courseID, on: app.db))
            #expect(course.brightspaceOrgUnitID == nil)
            #expect(course.brightspaceSyncUserID == nil)
        }
    }

    @Test func bindOrgUnitSetsBindingAndSyncIdentityWhenConnected() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "testinstructor").first())
            // Simulate a connected LEARN account for the instructor.
            try await BrightSpaceCredentialStore.save(
                valenceUserID: "vu", valenceUserKey: "vk", identityName: "Test Instructor",
                capturedByUserID: instructor.id, userID: instructor.id, on: app.db)

            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/instructor/brightspace/bind-org-unit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    try req.content.encode(["orgUnitID": "1106038"], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.headers.first(name: .location) == "/instructor/brightspace")
                })
            // The binder is recorded as the org unit + the course's sync identity
            // (verification is skipped here — no app creds → no live D2L call).
            let course = try #require(try await APICourse.find(courseID, on: app.db))
            #expect(course.brightspaceOrgUnitID == "1106038")
            #expect(course.brightspaceSyncUserID == instructor.id)
        }
    }

    // MARK: - Grade-objects feed

    @Test func gradeObjectsEmptyWhenUnconfigured() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await app.asyncTest(
                .GET, "/instructor/brightspace/grade-objects",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let compact = res.body.string
                        .replacingOccurrences(of: " ", with: "")
                        .replacingOccurrences(of: "\n", with: "")
                    #expect(compact == "[]")
                })
        }
    }

    // MARK: - Connection test (unconfigured)

    @Test func testConnectionReportsUnconfigured() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/instructor/brightspace/test",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    // With no identity connected for the course, the test reports
                    // failure — a JSON-spacing-robust proxy for the ok:false path.
                    #expect(res.body.string.contains("ok\":false"))
                    #expect(res.body.string.contains("not connected"))
                })
        }
    }

    // MARK: - Manual actions are no-op redirects when unconfigured

    @Test func syncNowRedirectsWhenUnconfigured() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/instructor/brightspace/sync-now",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor/brightspace")
                })
        }
    }

    // MARK: - Grade-item mapping save (returnTo routing)

    @Test func saveGradeItemReturnToBrightspaceRedirects() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "setup_bs_map", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_bs_map", title: "BS Map", isOpen: true, on: app)
            let assignmentID = assignment.publicID

            try await app.asyncTest(
                .POST, "/instructor/\(assignmentID)/brightspace",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["gradeObjectID": "78901", "returnTo": "brightspace", "_csrf": csrf],
                        as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor/brightspace")
                })

            let updated = try await APIAssignment.query(on: app.db)
                .filter(\.$publicID == assignmentID).first()
            #expect(updated?.brightspaceGradeObjectID == "78901")
        }
    }

    @Test func doNotSyncDropdownTokenExcludesAndMappingRestores() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "setup_bs_excl", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_bs_excl", title: "BS Excl", isOpen: true, on: app)
            let assignmentID = assignment.publicID

            // Selecting "Do not sync" in the dropdown submits the reserved token →
            // the assignment is excluded and any grade-item mapping is cleared.
            try await app.asyncTest(
                .POST, "/instructor/\(assignmentID)/brightspace",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        [
                            "gradeObjectID": BrightspaceSync.doNotSyncToken,
                            "returnTo": "brightspace", "_csrf": csrf,
                        ],
                        as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })
            let excluded = try await APIAssignment.query(on: app.db)
                .filter(\.$publicID == assignmentID).first()
            #expect(excluded?.brightspaceSyncExcluded == true)
            #expect(excluded?.brightspaceGradeObjectID == nil)

            // Picking a real grade item again clears the exclusion.
            try await app.asyncTest(
                .POST, "/instructor/\(assignmentID)/brightspace",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["gradeObjectID": "78901", "returnTo": "brightspace", "_csrf": csrf],
                        as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })
            let enabled = try await APIAssignment.query(on: app.db)
                .filter(\.$publicID == assignmentID).first()
            #expect(enabled?.brightspaceSyncExcluded == false)
            #expect(enabled?.brightspaceGradeObjectID == "78901")
        }
    }

    // MARK: - Push-all re-flags results for re-sync

    @Test func pushAllFlagsResultsForResync() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "setup_bs_push", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_bs_push", title: "BS Push", isOpen: true, on: app)
            let student = try await arInsertStudent(username: "bs_push_student", on: app)
            _ = try await arInsertSubmission(
                id: "sub_bs_push", testSetupID: "setup_bs_push", userID: try student.requireID(), on: app)

            // A previously-synced result (not pending, has a synced timestamp).
            let result = APIResult(
                id: "res_bs_push", submissionID: "sub_bs_push",
                collectionJSON: "{}", source: "worker")
            result.brightspaceSyncPending = false
            result.brightspaceSyncedAt = Date()
            try await result.save(on: app.db)

            try await app.asyncTest(
                .POST, "/instructor/\(assignment.publicID)/brightspace/push-all",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor/brightspace")
                })

            let reloaded = try #require(try await APIResult.find("res_bs_push", on: app.db))
            #expect(reloaded.brightspaceSyncPending == true)
            #expect((reloaded.brightspaceSyncError ?? "").isEmpty)
        }
    }

    // MARK: - Per-assignment sync counts (instructor LEARN tab)

    @Test func assignmentSyncCountsAreDedupedPerStudent() async throws {
        try await withAssignmentRoutesApp { app in
            // Configured + active course so the dashboard (with the assignment
            // mapping table) renders.
            app.brightSpaceAppCredentials = BrightSpaceAppCredentials(
                baseURL: "https://learn.test", appID: "a", appKey: "k", debounceSecs: 90)
            try await arInsertSetup(id: "setup_bs_counts", on: app)
            _ = try await arInsertAssignment(
                testSetupID: "setup_bs_counts", title: "Counts Lab", isOpen: true, on: app)

            // Student A submitted twice and both results synced. The columns count
            // distinct STUDENTS by their most recent attempt, so A is one synced
            // student — not two — even though there are two synced result rows.
            let studentA = try await arInsertStudent(username: "bs_counts_a", on: app)
            _ = try await arInsertSubmission(
                id: "sub_bs_a", testSetupID: "setup_bs_counts",
                userID: try studentA.requireID(), on: app)
            for id in ["res_a1", "res_a2"] {
                let synced = APIResult(
                    id: id, submissionID: "sub_bs_a", collectionJSON: "{}", source: "worker")
                synced.brightspaceSyncPending = false
                synced.brightspaceSyncedAt = Date()
                try await synced.save(on: app.db)
            }

            // Student B's only result errored → one failed student.
            let studentB = try await arInsertStudent(username: "bs_counts_b", on: app)
            _ = try await arInsertSubmission(
                id: "sub_bs_b", testSetupID: "setup_bs_counts",
                userID: try studentB.requireID(), on: app)
            let errored = APIResult(
                id: "res_b1", submissionID: "sub_bs_b", collectionJSON: "{}", source: "worker")
            errored.brightspaceSyncPending = false
            errored.brightspaceSyncError = "D2L rejected it"
            try await errored.save(on: app.db)

            let cookie = try await arLoginAsInstructor(on: app)
            try await app.asyncTest(
                .GET, "/instructor/brightspace",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("LEARN Assessment"))
                    // Synced = 1 distinct student (A), not 2 result rows; Failed = 1 (B).
                    #expect(html.contains("title=\"Synced to LEARN\">1<"))
                    #expect(!html.contains("title=\"Synced to LEARN\">2<"))
                    #expect(html.contains("bs-count-err"))
                })
        }
    }

    @Test func overrideOnlyRowCountsTowardAssignmentRollup() async throws {
        try await withAssignmentRoutesApp { app in
            // A no-submission student's grade rides on an override row; its
            // pending state must count toward the per-assignment rollup even
            // though there is no result row.
            app.brightSpaceAppCredentials = BrightSpaceAppCredentials(
                baseURL: "https://learn.test", appID: "a", appKey: "k", debounceSecs: 90)
            try await arInsertSetup(id: "setup_bs_ovr", on: app)
            _ = try await arInsertAssignment(
                testSetupID: "setup_bs_ovr", title: "Override Lab", isOpen: true, on: app)
            let student = try await arInsertStudent(username: "bs_ovr_student", on: app)

            let override = APIGradeOverride(
                testSetupID: "setup_bs_ovr", userID: try student.requireID(), overridePercent: 80)
            override.brightspaceSyncPending = true
            try await override.save(on: app.db)

            let cookie = try await arLoginAsInstructor(on: app)
            try await app.asyncTest(
                .GET, "/instructor/brightspace",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    // The override-only row contributes to hasSyncActivity — the
                    // assignment row appears in the mapping table.
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("Override Lab"))
                })
        }
    }

    // MARK: - Sync-log model + migration round-trip

    @Test func syncLogModelRoundTrips() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let entry = APIBrightSpaceSyncLog(
                courseID: courseID,
                testSetupID: "setup_log",
                assignmentTitle: "Logged Assignment",
                userID: UUID(),
                username: "log_student",
                orgUnitID: "123456",
                gradeObjectID: "78901",
                points: 9.5,
                status: .success,
                detail: nil)
            try await entry.save(on: app.db)

            let rows = try await APIBrightSpaceSyncLog.query(on: app.db)
                .filter(\.$courseID == courseID)
                .all()
            let found = try #require(rows.first { $0.username == "log_student" })
            #expect(found.status == "success")
            #expect(found.points == 9.5)
            #expect(found.gradeObjectID == "78901")
            #expect(found.attemptedAt != nil)
        }
    }
}
