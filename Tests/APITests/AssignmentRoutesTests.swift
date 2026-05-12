// Tests/APITests/AssignmentRoutesTests.swift
//
// Integration tests for Phase 7 instructor assignment management routes.
//
//   GET  /instructor
//   POST /instructor                       (publish → draft)
//   GET  /instructor/:id/validate
//   POST /instructor/:id/open
//   POST /instructor/:id/close
//   POST /instructor/:id/delete

import XCTest
import XCTVapor
@testable import chickadee_server
import Fluent
import Foundation
import Core

final class AssignmentRoutesTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = try await Application.make(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-art-\(UUID().uuidString)/")
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

    private func loginAsInstructor() async throws -> String {
        return try await loginUser(username: "testinstructor", password: "testpassword", role: "instructor", on: app)
    }

    private func loginAsStudent() async throws -> String {
        return try await loginUser(username: "teststudent", password: "testpassword", role: "student", on: app)
    }

    // MARK: - Setup helper

    private func makeTestCourseID() async throws -> UUID {
        if let existing = try await APICourse.query(on: app.db).filter(\.$code == "TEST101").first() {
            return try existing.requireID()
        }
        let course = APICourse(code: "TEST101", name: "Test Course", enrollmentMode: .auto)
        try await course.save(on: app.db)
        return try course.requireID()
    }

    @discardableResult
    private func insertSetup(id: String) async throws -> APITestSetup {
        let manifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10,"makefile":null}
        """
        let courseID = try await makeTestCourseID()
        let setup = APITestSetup(id: id, manifest: manifest, zipPath: tmpDir + "testsetups/\(id).zip", courseID: courseID)
        try await setup.save(on: app.db)
        return setup
    }

    @discardableResult
    private func insertAssignment(
        testSetupID: String,
        title: String,
        isOpen: Bool,
        dueAt: Date? = nil,
        deadlineOverrideActive: Bool = false
    ) async throws -> APIAssignment {
        let courseID = try await makeTestCourseID()
        let a = APIAssignment(
            testSetupID: testSetupID,
            title: title,
            dueAt: dueAt,
            isOpen: isOpen,
            deadlineOverrideActive: deadlineOverrideActive,
            courseID: courseID
        )
        try await a.save(on: app.db)
        return a
    }

    @discardableResult
    private func insertStudent(
        username: String = "student_retest",
        displayName: String? = nil,
        preferredName: String? = nil
    ) async throws -> APIUser {
        let hash = try Bcrypt.hash("testpassword")
        let student = APIUser(
            username: username,
            passwordHash: hash,
            role: "student",
            preferredName: preferredName,
            displayName: displayName
        )
        try await student.save(on: app.db)
        return student
    }

    @discardableResult
    private func insertUser(
        username: String,
        role: String,
        displayName: String? = nil
    ) async throws -> APIUser {
        let hash = try Bcrypt.hash("testpassword")
        let u = APIUser(
            username: username,
            passwordHash: hash,
            role: role,
            displayName: displayName
        )
        try await u.save(on: app.db)
        return u
    }

    @discardableResult
    private func insertSubmission(
        id: String,
        testSetupID: String,
        userID: UUID,
        attemptNumber: Int = 1,
        status: String = "complete"
    ) async throws -> APISubmission {
        let sub = APISubmission(
            id: id,
            testSetupID: testSetupID,
            zipPath: tmpDir + "submissions/\(id).zip",
            attemptNumber: attemptNumber,
            status: status,
            userID: userID,
            kind: APISubmission.Kind.student
        )
        try await sub.save(on: app.db)
        return sub
    }

    private func enrollStudentInTestCourse(_ student: APIUser) async throws {
        let courseID = try await makeTestCourseID()
        let enrollment = APICourseEnrollment(
            userID: try student.requireID(),
            courseID: courseID
        )
        try await enrollment.save(on: app.db)
    }

    private func multipartAssignmentBody(
        boundary: String,
        csrf: String,
        assignmentName: String,
        assignmentNotebook: String,
        solutionNotebook: String,
        suiteFiles: [(filename: String, contentType: String, content: String)] = [],
        suiteConfig: String? = nil
    ) -> ByteBuffer {
        var body = ByteBufferAllocator().buffer(capacity: 4096)

        func appendField(_ name: String, _ value: String) {
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.writeString(value)
            body.writeString("\r\n")
        }

        func appendFile(_ name: String, filename: String, contentType: String = "application/json", data: Data) {
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
            body.writeString("Content-Type: \(contentType)\r\n\r\n")
            body.writeBytes(data)
            body.writeString("\r\n")
        }

        appendField("_csrf", csrf)
        appendField("assignmentName", assignmentName)
        appendFile(
            "assignmentNotebookFile",
            filename: "assignment.ipynb",
            data: Data(assignmentNotebook.utf8)
        )
        appendFile(
            "solutionNotebookFile",
            filename: "solution.ipynb",
            data: Data(solutionNotebook.utf8)
        )
        for suiteFile in suiteFiles {
            appendFile(
                "suiteFiles",
                filename: suiteFile.filename,
                contentType: suiteFile.contentType,
                data: Data(suiteFile.content.utf8)
            )
        }
        if let suiteConfig {
            appendField("suiteConfig", suiteConfig)
        }
        body.writeString("--\(boundary)--\r\n")
        return body
    }

    private func multipartEditBody(
        boundary: String,
        csrf: String,
        assignmentName: String,
        assignmentNotebook: String,
        solutionNotebook: String,
        suiteConfig: String
    ) -> ByteBuffer {
        var body = ByteBufferAllocator().buffer(capacity: 4096)

        func appendField(_ name: String, _ value: String) {
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.writeString(value)
            body.writeString("\r\n")
        }

        func appendFile(_ name: String, filename: String, contentType: String = "application/json", data: Data) {
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
            body.writeString("Content-Type: \(contentType)\r\n\r\n")
            body.writeBytes(data)
            body.writeString("\r\n")
        }

        appendField("_csrf", csrf)
        appendField("assignmentName", assignmentName)
        appendFile(
            "assignmentNotebookFile",
            filename: "assignment.ipynb",
            data: Data(assignmentNotebook.utf8)
        )
        appendFile(
            "solutionNotebookFile",
            filename: "solution.ipynb",
            data: Data(solutionNotebook.utf8)
        )
        appendField("suiteConfig", suiteConfig)
        body.writeString("--\(boundary)--\r\n")
        return body
    }

    private func multipartBody(
        boundary: String,
        fields: [(String, String)],
        files: [(name: String, filename: String, contentType: String, data: Data)] = []
    ) -> ByteBuffer {
        var body = ByteBufferAllocator().buffer(capacity: 4096)

        func appendField(_ name: String, _ value: String) {
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.writeString(value)
            body.writeString("\r\n")
        }

        func appendFile(_ file: (name: String, filename: String, contentType: String, data: Data)) {
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\n")
            body.writeString("Content-Type: \(file.contentType)\r\n\r\n")
            body.writeBytes(file.data)
            body.writeString("\r\n")
        }

        fields.forEach(appendField)
        files.forEach(appendFile)
        body.writeString("--\(boundary)--\r\n")
        return body
    }

    func testCloseExpiredAssignmentsClosesOnlyEligibleAssignments() async throws {
        _ = try await insertSetup(id: "setup_deadline_close")
        let overdue = try await insertAssignment(
            testSetupID: "setup_deadline_close",
            title: "Overdue",
            isOpen: true,
            dueAt: Date().addingTimeInterval(-60)
        )

        _ = try await insertSetup(id: "setup_deadline_open")
        let noDeadline = try await insertAssignment(
            testSetupID: "setup_deadline_open",
            title: "No Deadline",
            isOpen: true
        )

        _ = try await insertSetup(id: "setup_deadline_override")
        let overridden = try await insertAssignment(
            testSetupID: "setup_deadline_override",
            title: "Override",
            isOpen: true,
            dueAt: Date().addingTimeInterval(-60),
            deadlineOverrideActive: true
        )

        let closedCount = try await closeExpiredAssignments(on: app.db, logger: app.logger)
        XCTAssertEqual(closedCount, 1)

        let overdueReloadedOptional = try await APIAssignment.find(overdue.id, on: app.db)
        XCTAssertNotNil(overdueReloadedOptional)
        let overdueReloaded = overdueReloadedOptional!
        XCTAssertFalse(overdueReloaded.isOpen)

        let noDeadlineReloadedOptional = try await APIAssignment.find(noDeadline.id, on: app.db)
        XCTAssertNotNil(noDeadlineReloadedOptional)
        let noDeadlineReloaded = noDeadlineReloadedOptional!
        XCTAssertTrue(noDeadlineReloaded.isOpen)

        let overriddenReloadedOptional = try await APIAssignment.find(overridden.id, on: app.db)
        XCTAssertNotNil(overriddenReloadedOptional)
        let overriddenReloaded = overriddenReloadedOptional!
        XCTAssertTrue(overriddenReloaded.isOpen)
    }

    func testInstructorCanReopenPastDueAssignmentWithOverride() async throws {
        _ = try await insertSetup(id: "setup_reopen_deadline")
        let assignment = try await insertAssignment(
            testSetupID: "setup_reopen_deadline",
            title: "Past Due",
            isOpen: false,
            dueAt: Date().addingTimeInterval(-60)
        )
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/\(assignment.publicID)/open", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.add(name: "x-csrf-token", value: csrf)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let reopenedOptional = try await APIAssignment.find(assignment.id, on: app.db)
        XCTAssertNotNil(reopenedOptional)
        let reopened = reopenedOptional!
        XCTAssertTrue(reopened.isOpen)
        XCTAssertEqual(reopened.deadlineOverrideActive, true)

        _ = try await closeExpiredAssignments(on: app.db, logger: app.logger)
        let stillOpenOptional = try await APIAssignment.find(assignment.id, on: app.db)
        XCTAssertNotNil(stillOpenOptional)
        let stillOpen = stillOpenOptional!
        XCTAssertTrue(stillOpen.isOpen)
    }

    private func makeZip(at path: String, entries: [(String, String)]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("assignment-routes-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for (name, contents) in entries {
            let fileURL = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.data(using: .utf8)?.write(to: fileURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-q", "-r", path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - GET /instructor

    func testStudentCannotAccessAssignments() async throws {
        let cookie = try await loginAsStudent()
        try await app.asyncTest(.GET, "/instructor", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .forbidden)
        })
    }

    func testInstructorCanAccessAssignments() async throws {
        let cookie = try await loginAsInstructor()
        try await app.asyncTest(.GET, "/instructor", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            // 500 expected because Leaf is not configured in tests — but middleware passed (not 401/403).
            XCTAssertNotEqual(res.status, .unauthorized)
            XCTAssertNotEqual(res.status, .forbidden)
        })
    }

    func testAssignmentsPageUsesDedicatedEnrollCSVPageLink() async throws {
        _ = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()

        try await app.asyncTest(.GET, "/instructor", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("href=\"/instructor/enroll-csv\""))
            XCTAssertFalse(html.contains("id=\"enroll-csv-file\""))
        })
    }

    func testAssignmentsPageDefaultsEnrolledStudentsToMostRecentLastSeenFirst() async throws {
        _ = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()
        let now = Date()

        let never = try await insertStudent(username: "never_seen_student", displayName: "Never Seen")
        try await enrollStudentInTestCourse(never)

        let older = try await insertStudent(username: "older_seen_student", displayName: "Older Seen")
        older.lastSeenAt = now.addingTimeInterval(-3600)
        try await older.save(on: app.db)
        try await enrollStudentInTestCourse(older)

        let recent = try await insertStudent(username: "recent_seen_student", displayName: "Recent Seen")
        recent.lastSeenAt = now
        try await recent.save(on: app.db)
        try await enrollStudentInTestCourse(recent)

        try await app.asyncTest(.GET, "/instructor", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("id=\"enrolled-students-table\""))
            XCTAssertTrue(html.contains("var sortCol = 3;"))
            XCTAssertTrue(html.contains("var sortAsc = false;"))
            let recentIndex = try XCTUnwrap(html.range(of: "recent_seen_student")?.lowerBound)
            let olderIndex = try XCTUnwrap(html.range(of: "older_seen_student")?.lowerBound)
            let neverIndex = try XCTUnwrap(html.range(of: "never_seen_student")?.lowerBound)
            XCTAssertLessThan(recentIndex, olderIndex)
            XCTAssertLessThan(olderIndex, neverIndex)
        })
    }

    /// Regression guard for v0.4.126 — admin/instructor users enrolled in a
    /// course (a common pattern: instructor enrolls themselves to test their
    /// own assignment via the same flow as a student) used to inflate the
    /// per-assignment "X / Y students submitted" badge on the `/instructor`
    /// dashboard.  Both counts now filter to enrolled users with role ==
    /// "student"; this test enrolls 2 students + 1 instructor + 1 admin in
    /// the test course, has each of them submit one student-kind submission,
    /// and asserts the badge for the assignment row reads "2 / 2" (not
    /// "4 / 4", which is what it showed pre-fix).
    func testInstructorDashboardBadgeCountsStudentsOnly() async throws {
        _ = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()

        // Two real students, both enrolled.
        let s1 = try await insertStudent(username: "stat_s1", displayName: "Student One")
        try await enrollStudentInTestCourse(s1)
        let s2 = try await insertStudent(username: "stat_s2", displayName: "Student Two")
        try await enrollStudentInTestCourse(s2)

        // One extra instructor + one admin, also enrolled in the same
        // course.  These are the users whose submissions should NOT be
        // reflected in either side of the badge.
        let i1 = try await insertUser(username: "stat_i1", role: "instructor",
                                      displayName: "Helper Instructor")
        try await enrollStudentInTestCourse(i1)
        let a1 = try await insertUser(username: "stat_a1", role: "admin",
                                      displayName: "Helper Admin")
        try await enrollStudentInTestCourse(a1)

        // Setup + assignment.
        try await insertSetup(id: "setup_dashboard_filter")
        let assignment = try await insertAssignment(
            testSetupID: "setup_dashboard_filter",
            title: "Mixed-Role Assignment",
            isOpen: true
        )

        // One student-kind submission per user — same path the instructor
        // would hit when testing their own assignment via the submit form.
        try await insertSubmission(id: "sub_s1", testSetupID: "setup_dashboard_filter",
                                   userID: try s1.requireID())
        try await insertSubmission(id: "sub_s2", testSetupID: "setup_dashboard_filter",
                                   userID: try s2.requireID())
        try await insertSubmission(id: "sub_i1", testSetupID: "setup_dashboard_filter",
                                   userID: try i1.requireID())
        try await insertSubmission(id: "sub_a1", testSetupID: "setup_dashboard_filter",
                                   userID: try a1.requireID())

        try await app.asyncTest(.GET, "/instructor", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string

            // The leaf template renders the badge as
            //   <span title="<X> / <Y> students submitted"><X> / <Y></span>
            // We assert against the title (a unique, structural attribute)
            // so the test doesn't depend on layout cosmetics.
            XCTAssertTrue(
                html.contains("title=\"2 / 2 students submitted\""),
                "Per-assignment badge should read '2 / 2 students submitted' "
                + "(only enrolled students count); admin/instructor "
                + "submissions and enrollments must be filtered out. "
                + "Assignment publicID=\(assignment.publicID)"
            )
            XCTAssertFalse(
                html.contains("title=\"4 / 4 students submitted\""),
                "Pre-v0.4.126 shape: admin/instructor inflated both X and Y. "
                + "The fix in AssignmentRoutes.swift list() must scope both "
                + "submittedStudentCount and enrolledStudentCount to "
                + "enrolledStudentIDs."
            )
        })
    }

    /// Dashboard card "Students With Browser Errors" counts distinct
    /// students who posted a client-side diagnostic (preflight or watchdog
    /// failure) on one of this course's test setups within the 24h window.
    /// Diagnostics outside the window, on other courses' setups, or with
    /// a null test_setup_id (stale) must not inflate the count.
    func testInstructorDashboardCountsStudentsWithBrowserErrors() async throws {
        let cookie = try await loginAsInstructor()

        let s1 = try await insertStudent(username: "browserErr_s1")
        try await enrollStudentInTestCourse(s1)
        let s2 = try await insertStudent(username: "browserErr_s2")
        try await enrollStudentInTestCourse(s2)
        let s3 = try await insertStudent(username: "browserErr_s3")
        try await enrollStudentInTestCourse(s3)

        try await insertSetup(id: "setup_browser_err")
        try await insertAssignment(
            testSetupID: "setup_browser_err",
            title: "Browser-error Metric Test",
            isOpen: true
        )

        // s1 hit a preflight failure right now → counts.
        let d1 = APIClientDiagnostic(
            userID: try s1.requireID(),
            testSetupID: "setup_browser_err",
            kind: "preflight_fail",
            failedChecks: "serviceWorker",
            userAgent: "TestUA"
        )
        try await d1.save(on: app.db)

        // s2 hit a watchdog timeout right now → counts.
        let d2 = APIClientDiagnostic(
            userID: try s2.requireID(),
            testSetupID: "setup_browser_err",
            kind: "watchdog_timeout",
            failedChecks: nil,
            userAgent: "TestUA"
        )
        try await d2.save(on: app.db)

        // s1 again, just to verify deduplication-by-user in the metric.
        let d1b = APIClientDiagnostic(
            userID: try s1.requireID(),
            testSetupID: "setup_browser_err",
            kind: "watchdog_timeout",
            failedChecks: nil,
            userAgent: "TestUA"
        )
        try await d1b.save(on: app.db)

        // s3 hit a diagnostic 48h ago → outside the window, must NOT count.
        let staleStudent = try await insertStudent(username: "browserErr_stale")
        try await enrollStudentInTestCourse(staleStudent)
        let dStale = APIClientDiagnostic(
            userID: try staleStudent.requireID(),
            testSetupID: "setup_browser_err",
            kind: "watchdog_timeout",
            failedChecks: nil,
            userAgent: "TestUA"
        )
        try await dStale.save(on: app.db)
        // Manually back-date so it falls outside the 24h window.
        dStale.createdAt = Date().addingTimeInterval(-48 * 60 * 60)
        try await dStale.save(on: app.db)

        // s3 hit a diagnostic with a null test_setup_id → unattributable,
        // must NOT count.
        let dOrphan = APIClientDiagnostic(
            userID: try s3.requireID(),
            testSetupID: nil,
            kind: "watchdog_timeout",
            failedChecks: nil,
            userAgent: "TestUA"
        )
        try await dOrphan.save(on: app.db)

        // Expected: 2 distinct students (s1, s2).
        try await app.asyncTest(.GET, "/instructor", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string

            let pattern = #"Students With Browser Errors</div>\s*<div class="diagnostic-value">(\d+)</div>"#
            let re = try NSRegularExpression(pattern: pattern)
            let nsr = NSRange(html.startIndex..., in: html)
            guard let match = re.firstMatch(in: html, range: nsr),
                  let valueRange = Range(match.range(at: 1), in: html)
            else {
                XCTFail("Could not locate 'Students With Browser Errors' metric card in dashboard HTML")
                return
            }
            XCTAssertEqual(
                String(html[valueRange]), "2",
                "Expected 2 students (s1 + s2 with recent diagnostics).  "
                + "Out-of-window diagnostics and diagnostics with a null "
                + "test_setup_id must not inflate the count."
            )
        })
    }

    // MARK: - POST /instructor (publish → creates draft)

    func testPublishCreatesDraftAssignment() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        try await insertSetup(id: "setup_pub1")

        try await app.asyncTest(.POST, "/instructor", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(
                ["testSetupID": "setup_pub1", "title": "Lab 1", "_csrf": csrf],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            // Redirects to /instructor/:id/validate
            XCTAssertEqual(res.status, .seeOther)
            let location = res.headers.first(name: .location) ?? ""
            XCTAssertTrue(location.contains("/instructor/") && location.contains("/validate"),
                          "Expected redirect to /instructor/:id/validate, got \(location)")
        })

        // Assignment should be in DB as draft (isOpen: false)
        let assignment = try await APIAssignment.query(on: app.db)
            .filter(\.$testSetupID == "setup_pub1")
            .first()
        XCTAssertNotNil(assignment)
        XCTAssertEqual(assignment?.title, "Lab 1")
        XCTAssertEqual(assignment?.isOpen, false)
    }

    func testPublishUnknownSetupReturnsBadRequest() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(
                ["testSetupID": "does_not_exist", "title": "Oops", "_csrf": csrf],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testPublishDuplicateSetupRedirects() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        try await insertSetup(id: "setup_dup")
        try await insertAssignment(testSetupID: "setup_dup", title: "Already Published", isOpen: false)

        try await app.asyncTest(.POST, "/instructor", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(
                ["testSetupID": "setup_dup", "title": "Duplicate", "_csrf": csrf],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            // Should redirect to /instructor without creating a second record
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/instructor")
        })

        let count = try await APIAssignment.query(on: app.db)
            .filter(\.$testSetupID == "setup_dup")
            .count()
        XCTAssertEqual(count, 1)
    }

    func testSaveNewAssignmentAllowsMissingTestSuites() async throws {
        _ = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)
        let boundary = "Boundary-New-NoSuites"
        let notebook = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#

        try await app.asyncTest(.POST, "/instructor/new/save", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart",
                subType: "form-data",
                parameters: ["boundary": boundary]
            )
            req.body = .init(buffer: self.multipartAssignmentBody(
                boundary: boundary,
                csrf: csrf,
                assignmentName: "No Tests Yet",
                assignmentNotebook: notebook,
                solutionNotebook: notebook
            ))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/instructor")
        })

        let assignment = try await APIAssignment.query(on: app.db)
            .filter(\.$title == "No Tests Yet")
            .first()
        XCTAssertNotNil(assignment)
        XCTAssertNil(assignment?.validationStatus)
        XCTAssertNil(assignment?.validationSubmissionID)

        let setupID = try XCTUnwrap(assignment?.testSetupID)
        let setup = try await APITestSetup.find(setupID, on: app.db)
        XCTAssertNotNil(setup)
        let setupManifest = try XCTUnwrap(setup?.manifest.data(using: .utf8))
        let props = try JSONDecoder().decode(TestProperties.self, from: setupManifest)
        XCTAssertTrue(props.testSuites.isEmpty)
    }

    func testSaveNewAssignmentPreservesMultipleUploadedSuiteFiles() async throws {
        _ = try await makeTestCourseID()
        app.migrations.add(CreateRunnerProfiles())
        app.migrations.add(CreateAssignmentRequirements())
        try await app.autoMigrate()
        let now = Date()
        let runnerProfile = RunnerProfile()
        runnerProfile.runnerID = "runner-multi-suite"
        runnerProfile.displayName = "Runner Multi Suite"
        runnerProfile.platform = "linux"
        runnerProfile.architecture = "x86_64"
        runnerProfile.languageVersionsJSON = "[]"
        runnerProfile.capabilitiesJSON = "[]"
        runnerProfile.profileHash = nil
        runnerProfile.lastRegisteredAt = now
        runnerProfile.lastSeenAt = now
        runnerProfile.isActive = true
        try await runnerProfile.save(on: app.db)
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)
        let boundary = "Boundary-New-MultiSuites"
        let notebook = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#
        let suiteConfig = """
        [
          {"index":0,"tier":"public","order":1,"points":1},
          {"index":1,"tier":"public","order":2,"points":1},
          {"index":2,"tier":"support","order":3,"points":1}
        ]
        """

        try await app.asyncTest(.POST, "/instructor/new/save", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart",
                subType: "form-data",
                parameters: ["boundary": boundary]
            )
            req.body = .init(buffer: self.multipartAssignmentBody(
                boundary: boundary,
                csrf: csrf,
                assignmentName: "Practice Lab",
                assignmentNotebook: notebook,
                solutionNotebook: notebook,
                suiteFiles: [
                    ("test_q1.py", "text/plain", "print('q1')"),
                    ("test_q2.py", "text/plain", "print('q2')"),
                    ("test.properties.json", "application/json", #"{"gradingMode":"browser"}"#)
                ],
                suiteConfig: suiteConfig
            ))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/instructor")
        })

        let assignment = try await APIAssignment.query(on: app.db)
            .filter(\.$title == "Practice Lab")
            .first()
        let setupID = try XCTUnwrap(assignment?.testSetupID)
        let setup = try await APITestSetup.find(setupID, on: app.db)
        XCTAssertNotNil(setup)

        let props = try JSONDecoder().decode(
            TestProperties.self,
            from: try XCTUnwrap(setup?.manifest.data(using: .utf8))
        )
        XCTAssertEqual(props.testSuites.map(\.script), ["test_q1.py", "test_q2.py"])

        let zipEntries = Set(listZipEntries(zipPath: try XCTUnwrap(setup?.zipPath)))
        XCTAssertTrue(zipEntries.contains("test_q1.py"))
        XCTAssertTrue(zipEntries.contains("test_q2.py"))
        XCTAssertTrue(zipEntries.contains("test.properties.json"))
    }

    // As of v0.4.79, suite metadata (displayName/tier/points/dependsOn) is
    // mutated live via `PUT /instructor/:id/suite`, not via the Save &
    // Validate form POST.  The two tests below exercise that flow.
    func testPutSuitePersistsDisplayNameForExistingSuiteFile() async throws {
        let courseID = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()
        let setupID = "setup_edit_display"
        let zipPath = tmpDir + "testsetups/\(setupID).zip"
        try makeZip(at: zipPath, entries: [("test_q1.py", "print('q1')")])
        let manifest = """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[{"tier":"public","script":"test_q1.py"}],"timeLimitSeconds":10,"makefile":null}
        """
        let setup = APITestSetup(id: setupID, manifest: manifest, zipPath: zipPath, notebookPath: tmpDir + "testsetups/notebooks/\(setupID)/assignment.ipynb", courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(publicID: "ABC123", testSetupID: setupID, title: "Practice Lab", dueAt: nil, isOpen: false, courseID: courseID)
        try await assignment.save(on: app.db)

        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/ABC123/edit", cookie: cookie, on: app)
        let body = #"""
        {"items":[
            {"kind":"script","script":{"script":"test_q1.py","tier":"public","points":1,"displayName":"BMI check","dependsOn":[]}}
        ]}
        """#
        try await app.asyncTest(.PUT, "/instructor/ABC123/suite", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.add(name: "x-csrf-token", value: csrf)
            req.headers.contentType = .json
            req.body = ByteBuffer(string: body)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok, res.body.string)
        })

        let savedSetup = try await APITestSetup.find(setupID, on: app.db)
        let props = try JSONDecoder().decode(
            TestProperties.self,
            from: try XCTUnwrap(savedSetup?.manifest.data(using: .utf8))
        )
        XCTAssertEqual(props.testSuites.count, 1)
        XCTAssertEqual(props.testSuites[0].name, "BMI check")
    }

    func testPutSuiteDisplayNameVisibleOnSubsequentEditPageLoad() async throws {
        let courseID = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()
        let setupID = "setup_edit_display_reload"
        let zipPath = tmpDir + "testsetups/\(setupID).zip"
        try makeZip(at: zipPath, entries: [("test_q1.py", "print('q1')")])
        let manifest = """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[{"tier":"public","script":"test_q1.py"}],"timeLimitSeconds":10,"makefile":null}
        """
        let setup = APITestSetup(id: setupID, manifest: manifest, zipPath: zipPath, notebookPath: tmpDir + "testsetups/notebooks/\(setupID)/assignment.ipynb", courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(publicID: "GHI789", testSetupID: setupID, title: "Practice Lab", dueAt: nil, isOpen: false, courseID: courseID)
        try await assignment.save(on: app.db)

        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/GHI789/edit", cookie: cookie, on: app)
        let body = #"""
        {"items":[
            {"kind":"script","script":{"script":"test_q1.py","tier":"public","points":1,"displayName":"BMI check","dependsOn":[]}}
        ]}
        """#
        try await app.asyncTest(.PUT, "/instructor/GHI789/suite", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.add(name: "x-csrf-token", value: csrf)
            req.headers.contentType = .json
            req.body = ByteBuffer(string: body)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok, res.body.string)
        })

        try await app.asyncTest(.GET, "/instructor/GHI789/edit", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            // The seeded suite-state JSON should carry the updated name.
            XCTAssertTrue(res.body.string.contains("\"displayName\":\"BMI check\""), res.body.string)
        })
    }

    func testNewAssignmentPageWiresSuiteTableJS() async throws {
        // Updated v0.4.132 (#435 / parity PR 1): the create page no
        // longer bundles suite changes through `chickadee:before-
        // multipart-submit` + `syncConfig()` + the legacy `suite-list.js`
        // IIFE.  Suite mutations now persist live via `suite-table.js`
        // against draft-scoped endpoints (`PUT /draft/suite`,
        // `POST /draft/scripts`, etc.); the multipart submit only
        // carries notebook bytes + assignment metadata.
        _ = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()

        try await app.asyncTest(.GET, "/instructor/new", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            // Legacy IIFE markers must be gone.
            XCTAssertFalse(html.contains("syncConfig();"),
                           "Legacy syncConfig() must not appear after the v0.4.132 rewrite")
            XCTAssertFalse(html.contains("chickadeeAddSuiteUploadFiles"),
                           "Legacy upload-queue global must not appear after the v0.4.132 rewrite")
        })
    }

    func testNewAssignmentPageOmitsLegacyTestColumn() async throws {
        _ = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()

        try await app.asyncTest(.GET, "/instructor/new", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let body = res.body.string
            XCTAssertFalse(body.contains("<th>Test?</th>"),
                           "Legacy `Test?` column header must not appear on the create page")
            XCTAssertFalse(body.contains("id=\"suite-config-table\""),
                           "Legacy `suite-config-table` must not appear after the v0.4.132 rewrite")
        })
    }

    func testUpdateNewAssignmentDraftCreatesBlankNotebookAndRendersDraftState() async throws {
        _ = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)
        let boundary = "Boundary-New-Draft-Create"

        var redirectLocation: String?
        try await app.asyncTest(.POST, "/instructor/new/draft", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart",
                subType: "form-data",
                parameters: ["boundary": boundary]
            )
            req.body = .init(buffer: self.multipartBody(
                boundary: boundary,
                fields: [
                    ("_csrf", csrf),
                    ("assignmentName", "Blank Draft Lab"),
                    ("draftAction", "create-assignment-notebook")
                ]
            ))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            redirectLocation = res.headers.first(name: .location)
            XCTAssertTrue((redirectLocation ?? "").contains("/instructor/new?draftID="))
        })

        let setup = try await APITestSetup.query(on: app.db).first()
        XCTAssertNotNil(setup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(setup?.notebookPath)))

        try await app.asyncTest(.GET, try XCTUnwrap(redirectLocation), beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("Blank Draft Lab"))
            XCTAssertTrue(html.contains("Assignment Notebook"))  // notebook table row
            XCTAssertTrue(html.contains("Edit"))
        })
    }

    func testSaveNewAssignmentFinalizesDraftAndPersistsRequirements() async throws {
        let courseID = try await makeTestCourseID()
        app.migrations.add(CreateAssignmentRequirements())
        try await app.autoMigrate()
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

        let setupID = "setup_draft_finalize"
        let zipPath = tmpDir + "testsetups/\(setupID).zip"
        _ = try createRunnerSetupZip(suiteFiles: [], suiteConfigJSON: nil, zipPath: zipPath)
        let manifest = try makeWorkerManifestJSON(testSuites: [], includeMakefile: false, gradingMode: "worker")
        let notebookDir = tmpDir + "testsetups/notebooks/\(setupID)/"
        try FileManager.default.createDirectory(atPath: notebookDir, withIntermediateDirectories: true)
        let assignmentPath = notebookDir + "assignment.ipynb"
        try defaultNotebookData(title: "Draft Finalize").write(to: URL(fileURLWithPath: assignmentPath))
        let solutionPath = draftSolutionNotebookPath(testSetupsDirectory: tmpDir + "testsetups/", setupID: setupID)
        try defaultNotebookData(title: "Draft Finalize Solution").write(to: URL(fileURLWithPath: solutionPath))

        let setup = APITestSetup(
            id: setupID,
            manifest: manifest,
            zipPath: zipPath,
            notebookPath: assignmentPath,
            courseID: courseID
        )
        try await setup.save(on: app.db)

        let boundary = "Boundary-New-Finalize-Draft"
        try await app.asyncTest(.POST, "/instructor/new/save", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart",
                subType: "form-data",
                parameters: ["boundary": boundary]
            )
            req.body = .init(buffer: self.multipartBody(
                boundary: boundary,
                fields: [
                    ("_csrf", csrf),
                    ("draftID", setupID),
                    ("assignmentName", "Draft-backed Lab"),
                    ("requiredLanguagesCSV", "python"),
                    ("requiredCapabilitiesCSV", "numpy, pandas")
                ]
            ))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/instructor")
        })

        let assignment = try await APIAssignment.query(on: app.db)
            .filter(\.$title == "Draft-backed Lab")
            .first()
        XCTAssertNotNil(assignment)
        let assignmentID = try XCTUnwrap(assignment?.id)

        let requirement = try await AssignmentRequirement.query(on: app.db)
            .filter(\.$assignmentID == assignmentID)
            .first()
        XCTAssertEqual(requirement?.requirementSpec.requiredLanguages.map(\.language), ["python"])
        XCTAssertEqual(requirement?.requirementSpec.requiredCapabilities.map(\.name), ["numpy", "pandas"])
    }

    func testSaveNewAssignmentFinalizesDraftWithGeneratedSuiteFilesVisibleOnEdit() async throws {
        let courseID = try await makeTestCourseID()
        app.migrations.add(CreateRunnerProfiles())
        app.migrations.add(CreateAssignmentRequirements())
        try await app.autoMigrate()

        let now = Date()
        let runnerProfile = RunnerProfile()
        runnerProfile.runnerID = "runner-generated-draft"
        runnerProfile.displayName = "Runner Generated Draft"
        runnerProfile.platform = "linux"
        runnerProfile.architecture = "x86_64"
        runnerProfile.languageVersionsJSON = "[]"
        runnerProfile.capabilitiesJSON = "[]"
        runnerProfile.profileHash = nil
        runnerProfile.lastRegisteredAt = now
        runnerProfile.lastSeenAt = now
        runnerProfile.isActive = true
        try await runnerProfile.save(on: app.db)

        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

        let setupID = "setup_generated_suite_finalize"
        let zipPath = tmpDir + "testsetups/\(setupID).zip"
        _ = try createRunnerSetupZip(suiteFiles: [], suiteConfigJSON: nil, zipPath: zipPath)
        let manifest = try makeWorkerManifestJSON(testSuites: [], includeMakefile: false, gradingMode: "worker")
        let notebookDir = tmpDir + "testsetups/notebooks/\(setupID)/"
        try FileManager.default.createDirectory(atPath: notebookDir, withIntermediateDirectories: true)
        let assignmentPath = notebookDir + "assignment.ipynb"
        try defaultNotebookData(title: "Generated Suite").write(to: URL(fileURLWithPath: assignmentPath))
        let solutionPath = draftSolutionNotebookPath(testSetupsDirectory: tmpDir + "testsetups/", setupID: setupID)
        try defaultNotebookData(title: "Generated Suite Solution").write(to: URL(fileURLWithPath: solutionPath))

        let setup = APITestSetup(
            id: setupID,
            manifest: manifest,
            zipPath: zipPath,
            notebookPath: assignmentPath,
            courseID: courseID
        )
        try await setup.save(on: app.db)

        let suiteConfig = """
        [
          {"source":"upload","isIncluded":true,"isTest":true,"tier":"public","order":1,"dependsOn":[],"points":1,"displayName":"alpha exists","index":0},
          {"source":"upload","isIncluded":true,"isTest":true,"tier":"public","order":2,"dependsOn":[],"points":1,"displayName":"beta exists","index":1}
        ]
        """
        let boundary = "Boundary-New-Generated-Suite"
        try await app.asyncTest(.POST, "/instructor/new/save", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart",
                subType: "form-data",
                parameters: ["boundary": boundary]
            )
            req.body = .init(buffer: self.multipartBody(
                boundary: boundary,
                fields: [
                    ("_csrf", csrf),
                    ("draftID", setupID),
                    ("assignmentName", "Generated Suite Lab"),
                    ("suiteConfig", suiteConfig)
                ],
                files: [
                    (name: "suiteFiles[]", filename: "test_alpha.py", contentType: "text/plain", data: Data("print('alpha')\n".utf8)),
                    (name: "suiteFiles[]", filename: "test_beta.py", contentType: "text/plain", data: Data("print('beta')\n".utf8))
                ]
            ))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/instructor")
        })

        let assignment = try await APIAssignment.query(on: app.db)
            .filter(\.$title == "Generated Suite Lab")
            .first()
        let savedSetup = try await APITestSetup.find(try XCTUnwrap(assignment?.testSetupID), on: app.db)
        let props = try JSONDecoder().decode(
            TestProperties.self,
            from: try XCTUnwrap(savedSetup?.manifest.data(using: .utf8))
        )
        XCTAssertEqual(props.testSuites.map(\.script), ["test_alpha.py", "test_beta.py"])

        let zipEntries = Set(listZipEntries(zipPath: try XCTUnwrap(savedSetup?.zipPath)))
        XCTAssertTrue(zipEntries.contains("test_alpha.py"), "test_alpha.py missing from zip; entries: \(zipEntries)")
        XCTAssertTrue(zipEntries.contains("test_beta.py"), "test_beta.py missing from zip; entries: \(zipEntries)")

        try await app.asyncTest(.GET, "/instructor/\(try XCTUnwrap(assignment?.publicID))/edit", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("test_alpha.py"))
            XCTAssertTrue(html.contains("test_beta.py"))
        })
    }

    func testSaveNewAssignmentRequiresCompatibleRunnerForValidation() async throws {
        let courseID = try await makeTestCourseID()
        app.migrations.add(CreateRunnerProfiles())
        app.migrations.add(CreateAssignmentRequirements())
        try await app.autoMigrate()
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

        let setupID = "setup_validation_runner_gate"
        let zipPath = tmpDir + "testsetups/\(setupID).zip"
        var suiteBuffer = ByteBufferAllocator().buffer(capacity: 16)
        suiteBuffer.writeString("print('ok')\n")
        _ = try createRunnerSetupZip(
            suiteFiles: [File(data: suiteBuffer, filename: "test_public.py")],
            suiteConfigJSON: nil,
            zipPath: zipPath
        )
        let manifest = try makeWorkerManifestJSON(
            testSuites: [
                ConfiguredSuiteEntry(
                    script: "test_public.py",
                    tier: "public",
                    order: 1,
                    dependsOn: [],
                    points: 1,
                    displayName: nil
                )
            ],
            includeMakefile: false,
            gradingMode: "worker"
        )
        let notebookDir = tmpDir + "testsetups/notebooks/\(setupID)/"
        try FileManager.default.createDirectory(atPath: notebookDir, withIntermediateDirectories: true)
        let assignmentPath = notebookDir + "assignment.ipynb"
        try defaultNotebookData(title: "Runner Gate").write(to: URL(fileURLWithPath: assignmentPath))
        let solutionPath = draftSolutionNotebookPath(testSetupsDirectory: tmpDir + "testsetups/", setupID: setupID)
        try defaultNotebookData(title: "Runner Gate Solution").write(to: URL(fileURLWithPath: solutionPath))

        let setup = APITestSetup(
            id: setupID,
            manifest: manifest,
            zipPath: zipPath,
            notebookPath: assignmentPath,
            courseID: courseID
        )
        try await setup.save(on: app.db)

        let boundary = "Boundary-New-Runner-Gate"
        try await app.asyncTest(.POST, "/instructor/new/save", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart",
                subType: "form-data",
                parameters: ["boundary": boundary]
            )
            req.body = .init(buffer: self.multipartBody(
                boundary: boundary,
                fields: [
                    ("_csrf", csrf),
                    ("draftID", setupID),
                    ("assignmentName", "Needs Matplotlib"),
                    ("requiredLanguagesCSV", "python"),
                    ("requiredCapabilitiesCSV", "matplotlib")
                ]
            ))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            let location = res.headers.first(name: .location) ?? ""
            XCTAssertTrue(location.contains("/instructor/new?"))
            XCTAssertTrue(location.contains("No%20compatible%20active%20runner%20is%20available%20to%20validate%20this%20assignment."))
        })

        let assignment = try await APIAssignment.query(on: app.db)
            .filter(\.$title == "Needs Matplotlib")
            .first()
        XCTAssertNil(assignment)
    }

    // MARK: - POST /instructor/:id/open

    func testOpenAssignmentSetsIsOpenTrue() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        try await insertSetup(id: "setup_open")
        let a = try await insertAssignment(testSetupID: "setup_open", title: "Draft", isOpen: false)
        let id = a.publicID

        try await app.asyncTest(.POST, "/instructor/\(id)/open", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/instructor")
        })

        let updated = try await APIAssignment.find(a.id, on: app.db)
        XCTAssertEqual(updated?.isOpen, true)
    }

    // MARK: - POST /instructor/:id/close

    func testCloseAssignmentSetsIsOpenFalse() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        try await insertSetup(id: "setup_close")
        let a = try await insertAssignment(testSetupID: "setup_close", title: "Open", isOpen: true)
        let id = a.publicID

        try await app.asyncTest(.POST, "/instructor/\(id)/close", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let updated = try await APIAssignment.find(a.id, on: app.db)
        XCTAssertEqual(updated?.isOpen, false)
    }

    // MARK: - POST /instructor/:id/delete

    func testDeleteAssignmentRemovesRecord() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        try await insertSetup(id: "setup_del")
        let a = try await insertAssignment(testSetupID: "setup_del", title: "To Remove", isOpen: false)
        let id = a.publicID

        try await app.asyncTest(.POST, "/instructor/\(id)/delete", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let gone = try await APIAssignment.find(a.id, on: app.db)
        XCTAssertNil(gone)
    }

    func testDeleteNonexistentAssignmentReturnsNotFound() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        let fakeID = "zzzzzz"

        try await app.asyncTest(.POST, "/instructor/\(fakeID)/delete", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    // MARK: - POST /instructor/:id/open — nonexistent

    func testOpenNonexistentAssignmentReturnsNotFound() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        let fakeID = "zzzzzz"

        try await app.asyncTest(.POST, "/instructor/\(fakeID)/open", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    // MARK: - POST /instructor/:assignmentID/submissions/:submissionID/retest

    func testRetestSubmissionRequeuesCompletedSubmission() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        try await insertSetup(id: "setup_retest")
        let assignment = try await insertAssignment(testSetupID: "setup_retest", title: "Lab Retest", isOpen: true)
        let assignmentID = assignment.publicID
        let student = try await insertStudent()

        let submission = APISubmission(
            id: "sub_retest_1",
            testSetupID: "setup_retest",
            zipPath: tmpDir + "submissions/sub_retest_1.zip",
            attemptNumber: 1,
            status: "complete",
            userID: student.id
        )
        submission.workerID = "worker-a"
        submission.assignedAt = Date()
        try await submission.save(on: app.db)

        try await app.asyncTest(.POST, "/instructor/\(assignmentID)/submissions/sub_retest_1/retest", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(
                ["returnTo": "/instructor/\(assignmentID)/submissions", "_csrf": csrf],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/instructor/\(assignmentID)/submissions")
        })

        let updated = try await APISubmission.find("sub_retest_1", on: app.db)
        XCTAssertEqual(updated?.status, "pending")
        XCTAssertNil(updated?.workerID)
        XCTAssertNil(updated?.assignedAt)
    }

    func testRetestSubmissionRequiresMatchingAssignmentSetup() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        try await insertSetup(id: "setup_a")
        try await insertSetup(id: "setup_b")
        let assignment = try await insertAssignment(testSetupID: "setup_a", title: "Lab A", isOpen: true)
        let assignmentID = assignment.publicID
        let student = try await insertStudent(username: "student_other_setup")

        let submission = APISubmission(
            id: "sub_retest_mismatch",
            testSetupID: "setup_b",
            zipPath: tmpDir + "submissions/sub_retest_mismatch.zip",
            attemptNumber: 1,
            status: "complete",
            userID: student.id
        )
        try await submission.save(on: app.db)

        try await app.asyncTest(.POST, "/instructor/\(assignmentID)/submissions/sub_retest_mismatch/retest", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    // MARK: - POST /instructor/:assignmentID/retest  (v0.4.93 "Retest all")

    /// The "Retest all" button flips every student submission on the
    /// assignment's test setup back to `pending` (so the worker regrades
    /// against the current manifest) and stamps `retestedByUserID` with
    /// the instructor who clicked.  Validation submissions for the same
    /// setup are intentionally excluded — they follow their own
    /// `scheduleValidationAfterSuiteEdit` path.
    func testRetestAllRequeuesStudentSubmissionsAndSkipsValidation() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        try await insertSetup(id: "setup_retest_all")
        let assignment = try await insertAssignment(
            testSetupID: "setup_retest_all", title: "Lab Retest All", isOpen: true
        )
        let assignmentID = assignment.publicID
        let student = try await insertStudent(username: "retest_all_student")

        // Two student submissions: one complete, one already pending.  The
        // "Retest all" button forces both into pending — the idempotent
        // skip only applies to the auto-save path.
        let subA = APISubmission(
            id: "sub_retest_all_a",
            testSetupID: "setup_retest_all",
            zipPath: tmpDir + "submissions/sub_retest_all_a.zip",
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
            zipPath: tmpDir + "submissions/sub_retest_all_b.zip",
            attemptNumber: 2,
            status: "pending",
            userID: student.id
        )
        try await subB.save(on: app.db)

        // A validation submission on the same setup — must be untouched.
        let validation = APISubmission(
            id: "sub_retest_all_validation",
            testSetupID: "setup_retest_all",
            zipPath: tmpDir + "submissions/sub_retest_all_validation.zip",
            attemptNumber: 1,
            status: "complete",
            userID: nil,
            kind: APISubmission.Kind.validation
        )
        try await validation.save(on: app.db)

        try await app.asyncTest(.POST, "/instructor/\(assignmentID)/retest", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let retestedA = try await APISubmission.find("sub_retest_all_a", on: app.db)
        XCTAssertEqual(retestedA?.status, "pending")
        XCTAssertNil(retestedA?.workerID)
        XCTAssertNil(retestedA?.assignedAt)
        XCTAssertNotNil(retestedA?.retestedAt)
        XCTAssertNotNil(retestedA?.retestedByUserID,
                        "Retest must stamp the instructor who clicked the button")

        let retestedB = try await APISubmission.find("sub_retest_all_b", on: app.db)
        XCTAssertEqual(retestedB?.status, "pending")
        XCTAssertNotNil(retestedB?.retestedAt,
                        "Manual Retest All forces every submission, even already-pending ones")

        let validationAfter = try await APISubmission.find("sub_retest_all_validation", on: app.db)
        XCTAssertEqual(validationAfter?.status, "complete",
                       "Validation submissions must be excluded from the retest fan-out")
        XCTAssertNil(validationAfter?.retestedAt)

        // The fan-out stamps `lastRetestedManifestHash` on the setup so a
        // subsequent cosmetic save won't re-trigger the same work.
        let setupAfter = try await APITestSetup.find("setup_retest_all", on: app.db)
        XCTAssertNotNil(setupAfter?.lastRetestedManifestHash)
    }

    /// The retest-all endpoint requires instructor role.  Students/guests
    /// hitting it should get a 403.
    func testRetestAllRequiresInstructorRole() async throws {
        try await insertSetup(id: "setup_retest_forbidden")
        let assignment = try await insertAssignment(
            testSetupID: "setup_retest_forbidden", title: "Lab RBAC", isOpen: true
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

        try await app.asyncTest(.POST, "/instructor/\(assignmentID)/retest", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
        }, afterResponse: { res in
            // RoleMiddleware short-circuits non-instructors to 403 (or 302
            // to login depending on the auth config).  Either way, the
            // submission must not be flipped.
            XCTAssertTrue(res.status == .forbidden
                          || res.status.code >= 300 && res.status.code < 400,
                          "Expected forbidden/redirect, got \(res.status)")
        })
    }

    /// Regression for v0.4.130 / launch-readiness #4.  Pre-fix, a suite
    /// edit (or save) when no compatible runner was available silently
    /// enqueued a validation submission that would never grade — the
    /// instructor saw `validationStatus = "pending"` indefinitely.  Now
    /// the helper pre-checks runner availability and falls back to a
    /// distinct `"no-runner"` status so the assignments view can show a
    /// specific reason.
    func testPutSuiteSetsNoRunnerStatusWhenNoCompatibleRunner() async throws {
        let courseID = try await makeTestCourseID()
        app.migrations.add(CreateRunnerProfiles())
        app.migrations.add(CreateAssignmentRequirements())
        try await app.autoMigrate()
        let cookie = try await loginAsInstructor()

        let setupID = "setup_no_runner"
        let zipPath = tmpDir + "testsetups/\(setupID).zip"
        try makeZip(at: zipPath, entries: [("test_q1.py", "print('q1')")])
        let manifest = """
        {"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"test_q1.py"}],"timeLimitSeconds":10,"makefile":null}
        """
        let setup = APITestSetup(
            id: setupID, manifest: manifest, zipPath: zipPath,
            notebookPath: tmpDir + "testsetups/notebooks/\(setupID)/assignment.ipynb",
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
        let solutionPath = tmpDir + "submissions/no_runner_solution.ipynb"
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
        try await app.asyncTest(.PUT, "/instructor/NRN001/suite", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.add(name: "x-csrf-token", value: csrf)
            req.headers.contentType = .json
            req.body = ByteBuffer(string: body)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok, res.body.string)
        })

        let after = try await APIAssignment.query(on: app.db)
            .filter(\.$publicID == "NRN001")
            .first()
        XCTAssertEqual(after?.validationStatus, "no-runner",
                       "scheduleValidationAfterSuiteEdit must set 'no-runner' when no compatible runner is available")

        // No new pending validation submission should have been enqueued.
        let pending = try await APISubmission.query(on: app.db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$kind == APISubmission.Kind.validation)
            .filter(\.$status == "pending")
            .count()
        XCTAssertEqual(pending, 0,
                       "Pre-check must skip the enqueue path when no compatible runner exists; otherwise the row sits forever")
    }

    /// Unit test for the new `loadAssignmentRequirementSpec` helper —
    /// confirms it round-trips a persisted `AssignmentRequirement` row
    /// into an `AssignmentRequirementSpec` and returns nil when no row
    /// exists.
    func testLoadAssignmentRequirementSpecRoundTripsPersistedRow() async throws {
        let courseID = try await makeTestCourseID()
        app.migrations.add(CreateAssignmentRequirements())
        try await app.autoMigrate()

        try await insertSetup(id: "setup_load_req")
        let assignment = APIAssignment(
            testSetupID: "setup_load_req", title: "Load Req",
            dueAt: nil, isOpen: false, courseID: courseID
        )
        try await assignment.save(on: app.db)

        // No row → nil.
        let none = try await loadAssignmentRequirementSpec(assignment: assignment, on: app.db)
        XCTAssertNil(none)

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
        XCTAssertEqual(loaded?.requiredPlatform, "linux")
        XCTAssertEqual(loaded?.requiredArchitecture, "x86_64")
        XCTAssertEqual(loaded?.requiredLanguages.map(\.language), ["python"])
        XCTAssertEqual(loaded?.requiredCapabilities.map(\.name), ["matplotlib"])
    }

    func testAssignmentSubmissionsUsesDisplayNameAndWaterlooTime() async throws {
        let cookie = try await loginAsInstructor()
        try await insertSetup(id: "setup_submissions_display_name")
        let assignment = try await insertAssignment(
            testSetupID: "setup_submissions_display_name",
            title: "Submission Summary",
            isOpen: true
        )
        let student = try await insertStudent(
            username: "jwallace",
            displayName: "Jim Wallace"
        )
        try await enrollStudentInTestCourse(student)

        let submission = APISubmission(
            id: "sub_display_name",
            testSetupID: "setup_submissions_display_name",
            zipPath: tmpDir + "submissions/sub_display_name.zip",
            attemptNumber: 1,
            status: "complete",
            filename: "submission.ipynb",
            userID: student.id,
            kind: APISubmission.Kind.student
        )
        try await submission.save(on: app.db)

        let persistedSubmission = try await APISubmission.find("sub_display_name", on: app.db)
        let submittedAt = try XCTUnwrap(persistedSubmission?.submittedAt)

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

        try await app.asyncTest(.GET, "/instructor/\(assignment.publicID)/submissions", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let body = res.body.string
                .replacingOccurrences(of: "\u{202F}", with: " ")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
            XCTAssertTrue(body.contains(">Wallace<"))
            XCTAssertTrue(body.contains(">Jim<"))
            XCTAssertTrue(body.contains(expectedDate))
            XCTAssertTrue(body.contains(expectedClock), "Expected clock '\(expectedClock)' in body: \(body)")
        })
    }

    // MARK: - POST /instructor/:assignmentID/students/:studentID/reset-notebook
    //
    // Instructor-driven reset of a student's working-copy notebook back to
    // the canonical starter from the test setup.  Used when a student
    // corrupts their own notebook (e.g. uploading a broken .ipynb that
    // overwrites their working copy on the server).  Past submissions are
    // NOT affected.

    /// Helper: write a starter notebook to disk and point a setup at it
    /// via `notebookPath`.  `notebookData(for:)` then returns these bytes
    /// when the reset handler asks for the starter.
    @discardableResult
    private func attachStarterNotebook(
        to setup: APITestSetup,
        bytes: Data
    ) async throws -> String {
        try FileManager.default.createDirectory(atPath: tmpDir + "starters/", withIntermediateDirectories: true)
        let starterPath = tmpDir + "starters/\(setup.id ?? "x").ipynb"
        try bytes.write(to: URL(fileURLWithPath: starterPath))
        setup.notebookPath = starterPath
        try await setup.save(on: app.db)
        return starterPath
    }

    /// Helper: write a "corrupted" working-copy notebook to the location
    /// the student's browser would have written one to.  Returns the path
    /// so the test can verify it gets overwritten.
    private func seedStudentWorkingCopy(
        setupID: String,
        userID: UUID,
        bytes: Data
    ) throws -> String {
        let path = app.directory.publicDirectory
            + "jupyterlite/files/users/\(userID.uuidString.lowercased())/\(setupID)/assignment.ipynb"
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try bytes.write(to: URL(fileURLWithPath: path))
        return path
    }

    func testResetStudentNotebookOverwritesWorkingCopyWithStarter() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        let setup = try await insertSetup(id: "setup_reset_ok")
        let starterBytes = Data(#"""
        {"nbformat":4,"nbformat_minor":5,"metadata":{"kernelspec":{"name":"python"}},"cells":[{"cell_type":"markdown","metadata":{},"source":["# Original assignment"]}]}
        """#.utf8)
        try await attachStarterNotebook(to: setup, bytes: starterBytes)
        let assignment = try await insertAssignment(
            testSetupID: "setup_reset_ok", title: "Reset Lab", isOpen: true
        )
        let assignmentID = assignment.publicID

        let student = try await insertStudent(username: "reset_student_ok")
        try await enrollStudentInTestCourse(student)
        let studentUUID = try student.requireID()

        let brokenBytes = Data(#"""
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","source":["# student-uploaded-garbage"]}]}
        """#.utf8)
        let workingCopyPath = try seedStudentWorkingCopy(
            setupID: "setup_reset_ok", userID: studentUUID, bytes: brokenBytes
        )

        try await app.asyncTest(
            .POST,
            "/instructor/\(assignmentID)/students/\(studentUUID.uuidString)/reset-notebook",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                try req.content.encode(
                    ["returnTo": "/instructor/\(assignmentID)/submissions", "_csrf": csrf],
                    as: .urlEncodedForm
                )
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/instructor/\(assignmentID)/submissions")
            }
        )

        // Working copy MUST have been overwritten — the bytes the route
        // writes are the starter notebook passed through
        // `normalizeNotebookForJupyterLite` (which adds/normalizes
        // kernelspec metadata), so they won't equal `starterBytes`
        // verbatim.  Instead, verify the broken content is GONE and a
        // valid Python-kernel notebook is in its place.
        let afterReset = try Data(contentsOf: URL(fileURLWithPath: workingCopyPath))
        XCTAssertNotEqual(afterReset, brokenBytes,
            "Working copy must no longer contain the student's broken bytes.")
        guard let resetJSON = try JSONSerialization.jsonObject(with: afterReset) as? [String: Any],
              let metadata  = resetJSON["metadata"] as? [String: Any],
              let kernelspec = metadata["kernelspec"] as? [String: Any]
        else {
            XCTFail("Reset working copy is not a valid normalized notebook"); return
        }
        XCTAssertEqual(kernelspec["name"] as? String, "python",
            "Starter must be normalized to Python (Pyodide) kernel.")
        // Sanity: starter contains the original markdown cell content
        let resetText = String(data: afterReset, encoding: .utf8) ?? ""
        XCTAssertTrue(resetText.contains("Original assignment"),
            "Reset must have come from the starter, not the student upload.")
    }

    /// The reset must NOT delete past submissions — they remain on disk
    /// and in the DB for instructor review.  Only the live working-copy
    /// notebook is overwritten.
    func testResetStudentNotebookDoesNotTouchPriorSubmissions() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        let setup = try await insertSetup(id: "setup_reset_keep_subs")
        try await attachStarterNotebook(
            to: setup,
            bytes: Data(#"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#.utf8)
        )
        let assignment = try await insertAssignment(
            testSetupID: "setup_reset_keep_subs", title: "Lab", isOpen: true
        )
        let assignmentID = assignment.publicID
        let student = try await insertStudent(username: "reset_student_keep_subs")
        try await enrollStudentInTestCourse(student)
        let studentUUID = try student.requireID()

        try await insertSubmission(
            id: "sub_kept_1",
            testSetupID: "setup_reset_keep_subs",
            userID: studentUUID
        )

        try await app.asyncTest(
            .POST,
            "/instructor/\(assignmentID)/students/\(studentUUID.uuidString)/reset-notebook",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
            }
        )

        let surviving = try await APISubmission.find("sub_kept_1", on: app.db)
        XCTAssertNotNil(surviving, "Prior submission must remain after notebook reset.")
    }

    func testResetStudentNotebookRejectsUnenrolledStudent() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        let setup = try await insertSetup(id: "setup_reset_unenrolled")
        try await attachStarterNotebook(
            to: setup,
            bytes: Data(#"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#.utf8)
        )
        let assignment = try await insertAssignment(
            testSetupID: "setup_reset_unenrolled", title: "Lab", isOpen: true
        )
        let assignmentID = assignment.publicID
        let strangerID = UUID()  // not enrolled in this course

        try await app.asyncTest(
            .POST,
            "/instructor/\(assignmentID)/students/\(strangerID.uuidString)/reset-notebook",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            }
        )
    }

    // MARK: - Regression tests: assignment creation bug fixes

    /// Bug #2 regression: browser posts suiteFiles with "suiteFiles[]" field name and includes extra
    /// JSON fields in suiteConfig (source, isIncluded, dependsOn: [], displayName: null) that the
    /// server must ignore. Files must land in the zip, the manifest must list them correctly, and
    /// a validation job must be queued when at least one test suite entry is present.
    func testSaveNewAssignmentWithBrowserFormatSuiteFilesAndFieldName() async throws {
        _ = try await makeTestCourseID()
        app.migrations.add(CreateRunnerProfiles())
        app.migrations.add(CreateAssignmentRequirements())
        try await app.autoMigrate()

        // Register an active runner so the validation-runner gate passes.
        let now = Date()
        let runnerProfile = RunnerProfile()
        runnerProfile.runnerID = "runner-browser-fmt"
        runnerProfile.displayName = "Runner Browser Format"
        runnerProfile.platform = "linux"
        runnerProfile.architecture = "x86_64"
        runnerProfile.languageVersionsJSON = "[]"
        runnerProfile.capabilitiesJSON = "[]"
        runnerProfile.profileHash = nil
        runnerProfile.lastRegisteredAt = now
        runnerProfile.lastSeenAt = now
        runnerProfile.isActive = true
        try await runnerProfile.save(on: app.db)

        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)
        let boundary = "Boundary-BrowserFmt"
        let notebook = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#

        // Exact JSON that syncConfig() produces in assignment-new.leaf:
        // extra fields (source, isIncluded) must be silently ignored by SuiteConfigRow.
        let suiteConfig = """
        [
          {"source":"upload","isIncluded":true,"isTest":true,"tier":"public","order":1,"dependsOn":[],"points":1,"displayName":null,"index":0},
          {"source":"upload","isIncluded":true,"isTest":false,"tier":"support","order":2,"dependsOn":[],"points":1,"displayName":null,"index":1}
        ]
        """

        var body = ByteBufferAllocator().buffer(capacity: 4096)
        func field(_ name: String, _ value: String) {
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.writeString(value + "\r\n")
        }
        func file(_ name: String, filename: String, contentType: String, content: String) {
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
            body.writeString("Content-Type: \(contentType)\r\n\r\n")
            body.writeString(content + "\r\n")
        }
        field("_csrf", csrf)
        field("assignmentName", "Browser Format Lab")
        file("assignmentNotebookFile", filename: "assignment.ipynb", contentType: "application/json", content: notebook)
        file("solutionNotebookFile",   filename: "solution.ipynb",   contentType: "application/json", content: notebook)
        // "suiteFiles[]" with brackets — exact field name sent by the browser's FormData API.
        file("suiteFiles[]", filename: "test_bmi.py", contentType: "text/plain", content: "print('test bmi')")
        file("suiteFiles[]", filename: "helpers.py",  contentType: "text/plain", content: "# helpers")
        field("suiteConfig", suiteConfig)
        body.writeString("--\(boundary)--\r\n")

        try await app.asyncTest(.POST, "/instructor/new/save", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart", subType: "form-data",
                parameters: ["boundary": boundary]
            )
            req.body = .init(buffer: body)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/instructor")
        })

        let assignment = try await APIAssignment.query(on: app.db)
            .filter(\.$title == "Browser Format Lab")
            .first()
        let setupID = try XCTUnwrap(assignment?.testSetupID)
        let setup   = try await APITestSetup.find(setupID, on: app.db)

        // Manifest: test_bmi.py (isTest:true, tier:public) → 1 suite entry; helpers.py → support, not listed.
        let props = try JSONDecoder().decode(
            TestProperties.self,
            from: try XCTUnwrap(setup?.manifest.data(using: .utf8))
        )
        XCTAssertEqual(props.testSuites.map(\.script), ["test_bmi.py"],
                       "test_bmi.py must be the only test suite entry in manifest")

        // Both files must be present in the zip (support files are stored even if not in manifest).
        let zipEntries = Set(listZipEntries(zipPath: try XCTUnwrap(setup?.zipPath)))
        XCTAssertTrue(zipEntries.contains("test_bmi.py"), "test_bmi.py missing from zip; entries: \(zipEntries)")
        XCTAssertTrue(zipEntries.contains("helpers.py"),  "helpers.py missing from zip; entries: \(zipEntries)")

        // Validation job must have been queued (Bug #2: was never queued when DataTransfer files
        // were absent from FormData, causing testSuites to be empty and shouldQueueValidation=false).
        XCTAssertEqual(assignment?.validationStatus, "pending")
        XCTAssertNotNil(assignment?.validationSubmissionID,
                        "validationSubmissionID must be set when suite files are present")
    }

    func testEditPageShowsUploadedSolutionNotebookFilenameAfterCreate() async throws {
        _ = try await makeTestCourseID()
        app.migrations.add(CreateRunnerProfiles())
        try await app.autoMigrate()
        let now = Date()
        let runnerProfile = RunnerProfile()
        runnerProfile.runnerID = "runner-solution-name"
        runnerProfile.displayName = "Runner Solution Name"
        runnerProfile.platform = "linux"
        runnerProfile.architecture = "x86_64"
        runnerProfile.languageVersionsJSON = "[]"
        runnerProfile.capabilitiesJSON = "[]"
        runnerProfile.profileHash = nil
        runnerProfile.lastRegisteredAt = now
        runnerProfile.lastSeenAt = now
        runnerProfile.isActive = true
        try await runnerProfile.save(on: app.db)
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

        let boundary = "Boundary-Solution-Filename"
        let notebook = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#
        let solutionName = "BMI Boundary Cases.ipynb"
        let suiteConfig = """
        [
          {"index":0,"isTest":true,"tier":"public","order":1,"points":1,"displayName":"Smoke test"}
        ]
        """

        try await app.asyncTest(.POST, "/instructor/new/save", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart",
                subType: "form-data",
                parameters: ["boundary": boundary]
            )
            req.body = .init(buffer: self.multipartBody(
                boundary: boundary,
                fields: [
                    ("_csrf", csrf),
                    ("assignmentName", "Named Solution Lab"),
                    ("suiteConfig", suiteConfig)
                ],
                files: [
                    (
                        name: "assignmentNotebookFile",
                        filename: "starter.ipynb",
                        contentType: "application/json",
                        data: Data(notebook.utf8)
                    ),
                    (
                        name: "solutionNotebookFile",
                        filename: solutionName,
                        contentType: "application/json",
                        data: Data(notebook.utf8)
                    ),
                    (
                        name: "suiteFiles[]",
                        filename: "test_smoke.py",
                        contentType: "text/plain",
                        data: Data("print('ok')\n".utf8)
                    )
                ]
            ))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/instructor")
        })

        let assignment = try await APIAssignment.query(on: app.db)
            .filter(\.$title == "Named Solution Lab")
            .first()
        let validationID = try XCTUnwrap(assignment?.validationSubmissionID)
        let validationSubmission = try await APISubmission.find(validationID, on: app.db)
        XCTAssertEqual(validationSubmission?.filename, solutionName)

        try await app.asyncTest(.GET, "/instructor/\(try XCTUnwrap(assignment?.publicID))/edit", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains(solutionName), html)
        })
    }

    /// v0.4.132 regression (was: bug #1 regression on the legacy
    /// upload-queue path).  After parity PR 1 of #433 dropped the
    /// `suite-list.js` IIFE in favor of `suite-table.js` + the
    /// per-script `POST /draft/scripts` endpoint, the create page
    /// hands generated/edited scripts to the suite table via
    /// `chickadeeAddExistingSuiteScript`.  This test creates a draft
    /// (so the suite-editor block is rendered) and confirms the
    /// page ships the wiring points so the gen-tests panel and the
    /// CodeMirror script editor can stream new scripts straight onto
    /// the suite editor without a multipart bundle.
    func testNewAssignmentPageWiresGeneratedScriptsThroughSuiteTable() async throws {
        _ = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

        // Create a draft via the same multipart path the UI uses.
        let boundary = "Boundary-Suite-Table-Wiring"
        var redirectLocation: String?
        try await app.asyncTest(.POST, "/instructor/new/draft", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart",
                subType: "form-data",
                parameters: ["boundary": boundary]
            )
            req.body = .init(buffer: self.multipartBody(
                boundary: boundary,
                fields: [
                    ("_csrf", csrf),
                    ("assignmentName", "Suite Table Wiring Lab"),
                    ("draftAction", "create-assignment-notebook")
                ]
            ))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            redirectLocation = res.headers.first(name: .location)
        })

        try await app.asyncTest(.GET, try XCTUnwrap(redirectLocation), beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("/suite-table.js"),
                          "Create page must load suite-table.js once a draft exists (v0.4.132)")
            XCTAssertTrue(html.contains("chickadeeAddExistingSuiteScript"),
                          "Create page must wire chickadeeAddExistingSuiteScript so " +
                          "generated/edited scripts land in the suite editor live")
            XCTAssertTrue(html.contains("/instructor/new/draft/scripts"),
                          "Generated scripts and the CodeMirror save flow must POST to " +
                          "the draft scripts endpoint, not bundle into the multipart submit")
        })
    }

    /// Bug #1 regression: the edit assignment page must include JavaScript for the edit button
    /// on newly uploaded (not-yet-saved) suite file rows.
    func testEditAssignmentPageContainsEditButtonForUploadedSuiteItems() async throws {
        let courseID = try await makeTestCourseID()
        let cookie   = try await loginAsInstructor()
        let setupID  = "setup_edit_upload_btn_reg"
        let zipPath  = tmpDir + "testsetups/\(setupID).zip"
        try makeZip(at: zipPath, entries: [("test_q1.py", "print('q1')")])
        let manifest = """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[{"tier":"public","script":"test_q1.py"}],"timeLimitSeconds":10,"makefile":null}
        """
        let setup = APITestSetup(
            id: setupID, manifest: manifest, zipPath: zipPath,
            notebookPath: tmpDir + "testsetups/notebooks/\(setupID)/assignment.ipynb",
            courseID: courseID
        )
        try await setup.save(on: app.db)
        let assignment = APIAssignment(
            publicID: "RGRN01", testSetupID: setupID, title: "Edit Btn Regression",
            dueAt: nil, isOpen: false, courseID: courseID
        )
        try await assignment.save(on: app.db)

        try await app.asyncTest(.GET, "/instructor/RGRN01/edit", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            // The rowHTML JS function for new (uploaded) items must contain the edit-button class.
            XCTAssertTrue(html.contains("suite-edit-upload-btn"),
                          "Edit assignment page must contain suite-edit-upload-btn for newly uploaded suite items")
        })
    }

    /// Bug #3 regression: GET /instructor/script-templates must return a non-empty JSON dict
    /// with keys for both Python and shell template types. The edit page's fetchTemplates()
    /// now calls this endpoint (was previously broken, returning null).
    func testScriptTemplatesEndpointReturnsTemplatesForAllTypes() async throws {
        _ = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()

        try await app.asyncTest(.GET, "/instructor/script-templates", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let json = try JSONDecoder().decode([String: String].self, from: Data(res.body.readableBytesView))
            // Must include at least one Python template and one shell template.
            XCTAssertTrue(json.keys.contains(where: { $0.hasPrefix("py:") }),
                          "Expected at least one py: key in script templates, got: \(json.keys.sorted())")
            XCTAssertTrue(json.keys.contains(where: { $0.hasPrefix("sh:") }),
                          "Expected at least one sh: key in script templates, got: \(json.keys.sorted())")
            // Values must be non-empty script content.
            for (key, content) in json {
                XCTAssertFalse(content.isEmpty, "Template '\(key)' must have non-empty content")
            }
        })
    }
}
