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
import XCTVapor

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
                    #expect(html.contains("BrightSpace"))
                    // brightSpaceClient is nil in tests → not-configured branch.
                    #expect(html.contains("not configured on this server"))
                })
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
                    // The "not configured" message only appears on the ok:false
                    // path, so it's a JSON-spacing-robust proxy for the failure.
                    #expect(res.body.string.contains("not configured"))
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

    @Test func retryFailedRedirectsWhenUnconfigured() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/instructor/brightspace/retry-failed",
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
