// Tests/APITests/AssignmentRoutesNotebookTests.swift
//
// Split from AssignmentRoutesTests.swift.  See AssignmentRoutesTestCase.swift
// for shared helpers (auth, fixtures, multipart builders, zip + notebook
// staging).

import Core
import Fluent
import Foundation
import XCTVapor
import XCTest

@testable import chickadee_server

final class AssignmentRoutesNotebookTests: AssignmentRoutesTestCase {

    // MARK: - POST /instructor/:assignmentID/students/:studentID/reset-notebook
    //
    // Instructor-driven reset of a student's working-copy notebook back to
    // the canonical starter from the test setup.  Used when a student
    // corrupts their own notebook (e.g. uploading a broken .ipynb that
    // overwrites their working copy on the server).  Past submissions are
    // NOT affected.

    func testResetStudentNotebookOverwritesWorkingCopyWithStarter() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        let setup = try await insertSetup(id: "setup_reset_ok")
        let starterBytes = Data(
            #"""
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

        let brokenBytes = Data(
            #"""
            {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","source":["# student-uploaded-garbage"]}]}
            """#.utf8)
        let workingCopyPath = try seedStudentWorkingCopy(
            setupID: "setup_reset_ok", userID: studentUUID, bytes: brokenBytes
        )

        // Capture mtime before the reset so we can prove the file was
        // overwritten (mtime bumped) — that's the signal `notebook.js`
        // uses to force-reseed the browser's IndexedDB copy.
        let mtimeBefore =
            (try FileManager.default.attributesOfItem(atPath: workingCopyPath)[.modificationDate] as? Date)
            ?? Date.distantPast
        try await Task.sleep(nanoseconds: 1_100_000_000)  // ensure ≥1s mtime resolution

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
        XCTAssertNotEqual(
            afterReset, brokenBytes,
            "Working copy must no longer contain the student's broken bytes.")
        guard let resetJSON = try JSONSerialization.jsonObject(with: afterReset) as? [String: Any],
            let metadata = resetJSON["metadata"] as? [String: Any],
            let kernelspec = metadata["kernelspec"] as? [String: Any]
        else {
            XCTFail("Reset working copy is not a valid normalized notebook"); return
        }
        XCTAssertEqual(
            kernelspec["name"] as? String, "python",
            "Starter must be normalized to Python (Pyodide) kernel.")
        // Sanity: starter contains the original markdown cell content
        let resetText = String(data: afterReset, encoding: .utf8) ?? ""
        XCTAssertTrue(
            resetText.contains("Original assignment"),
            "Reset must have come from the starter, not the student upload.")

        // mtime must have advanced — this is the signal `notebook.js` uses
        // to force-reseed the browser's IndexedDB on the student's next
        // visit.  Without the bump, the v0.4.153 cache-bust wouldn't fire.
        let mtimeAfter =
            (try FileManager.default.attributesOfItem(atPath: workingCopyPath)[.modificationDate] as? Date)
            ?? Date.distantPast
        XCTAssertGreaterThan(
            mtimeAfter, mtimeBefore,
            "Reset must bump the working-copy file mtime so notebook.js force-reseeds the browser's local copy.")
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
    // MARK: - GET /:courseCode/students/:urlToken/submissions

    /// The dashboard roster lists every enrolled user (students, plus
    /// instructors/admins enrolled for testing).  Clicking any of them used
    /// to 404 unless the target had role == "student".  Now any enrolled
    /// user's course-scoped submissions are viewable, and the row appears
    /// once-per-assignment with a link to the latest submission.
    func testCourseStudentSubmissionsPageWorksForEnrolledInstructor() async throws {
        _ = try await app.testCourseID(enrollmentMode: .auto)
        let cookie = try await loginAsInstructor()

        // Enroll a second instructor in the same course and give them a submission.
        let otherInstructor = try await insertUser(
            username: "other_instructor",
            role: "instructor",
            displayName: "Other Instructor"
        )
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        try await APICourseEnrollment(
            userID: try otherInstructor.requireID(),
            courseID: courseID
        ).save(on: app.db)

        _ = try await insertSetup(id: "instr_view_setup")
        _ = try await insertAssignment(
            testSetupID: "instr_view_setup",
            title: "Visible Assignment",
            isOpen: true
        )
        _ = try await insertSubmission(
            id: "instr_view_sub",
            testSetupID: "instr_view_setup",
            userID: try otherInstructor.requireID()
        )

        let url = "/TEST101/students/\(try otherInstructor.requireURLToken())/submissions"
        try await app.asyncTest(
            .GET, url,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(
                    res.status, .ok,
                    "Course-scoped submissions page must render for an enrolled non-student")
                XCTAssertTrue(
                    res.body.string.contains("Visible Assignment"),
                    "Grouped page must show the assignment title row for this student")
                XCTAssertTrue(
                    res.body.string.contains("instr_view_sub"),
                    "Latest-submission link should include the submission ID")
            })
    }

    /// #556: the old `/students/<username>/...` URL shape no longer routes
    /// after the switch to opaque `urlToken`s.  Bookmarks against the
    /// legacy URL must 404 cleanly instead of resolving by username — that
    /// would defeat the privacy goal (usernames in logs / Referer headers).
    func testCourseStudentSubmissionsPage404sForLegacyUsernameURL() async throws {
        _ = try await app.testCourseID(enrollmentMode: .auto)
        let cookie = try await loginAsInstructor()

        let student = try await insertStudent(username: "legacy_url_student")
        try await enrollStudentInTestCourse(student)

        // The username happens to be alphanumeric-only so it satisfies the
        // urlToken character set.  The route should still 404 because the
        // resolver looks up by `urlToken`, not by `username`.
        let url = "/TEST101/students/legacy_url_student/submissions"
        try await app.asyncTest(
            .GET, url,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(
                    res.status, .notFound,
                    "Legacy `/students/<username>` URL must 404 — only the urlToken shape is valid")
            })
    }

    /// Non-enrolled users (in any role) still 404 — the page is course-scoped
    /// and must not leak submissions for users outside the active course.
    func testCourseStudentSubmissionsPage404sForNonEnrolledUser() async throws {
        _ = try await app.testCourseID(enrollmentMode: .auto)
        let cookie = try await loginAsInstructor()

        let stranger = try await insertUser(
            username: "stranger_user",
            role: "student",
            displayName: "Stranger"
        )

        let url = "/TEST101/students/\(try stranger.requireURLToken())/submissions"
        try await app.asyncTest(
            .GET, url,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(
                    res.status, .notFound,
                    "Non-enrolled user must 404 — enrollment is the only access gate")
            })
    }
}
