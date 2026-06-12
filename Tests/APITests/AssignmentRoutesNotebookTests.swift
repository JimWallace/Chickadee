// Tests/APITests/AssignmentRoutesNotebookTests.swift
//
// Split from AssignmentRoutesTests.swift.  See AssignmentRoutesTestCase.swift
// for shared helpers (auth, fixtures, multipart builders, zip + notebook
// staging).

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct AssignmentRoutesNotebookTests {

    // MARK: - POST /instructor/:assignmentID/students/:studentID/reset-notebook
    //
    // Instructor-driven reset of a student's working-copy notebook back to
    // the canonical starter from the test setup.  Used when a student
    // corrupts their own notebook (e.g. uploading a broken .ipynb that
    // overwrites their working copy on the server).  Past submissions are
    // NOT affected.

    @Test func resetStudentNotebookOverwritesWorkingCopyWithStarter() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            let setup = try await arInsertSetup(id: "setup_reset_ok", on: app)
            let starterBytes = Data(
                #"""
                {"nbformat":4,"nbformat_minor":5,"metadata":{"kernelspec":{"name":"python"}},"cells":[{"cell_type":"markdown","metadata":{},"source":["# Original assignment"]}]}
                """#.utf8)
            try await arAttachStarterNotebook(to: setup, bytes: starterBytes, on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_reset_ok", title: "Reset Lab", isOpen: true, on: app
            )
            let assignmentID = assignment.publicID

            let student = try await arInsertStudent(username: "reset_student_ok", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            let studentUUID = try student.requireID()

            let brokenBytes = Data(
                #"""
                {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","source":["# student-uploaded-garbage"]}]}
                """#.utf8)
            let workingCopyPath = try arSeedStudentWorkingCopy(
                setupID: "setup_reset_ok", userID: studentUUID, bytes: brokenBytes, on: app
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
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor/\(assignmentID)/submissions")
                }
            )

            // Working copy MUST have been overwritten — the bytes the route
            // writes are the starter notebook passed through
            // `normalizeNotebookForJupyterLite` (which adds/normalizes
            // kernelspec metadata), so they won't equal `starterBytes`
            // verbatim.  Instead, verify the broken content is GONE and a
            // valid Python-kernel notebook is in its place.
            let afterReset = try Data(contentsOf: URL(fileURLWithPath: workingCopyPath))
            #expect(afterReset != brokenBytes, "Working copy must no longer contain the student's broken bytes.")
            guard let resetJSON = try JSONSerialization.jsonObject(with: afterReset) as? [String: Any],
                let metadata = resetJSON["metadata"] as? [String: Any],
                let kernelspec = metadata["kernelspec"] as? [String: Any]
            else {
                Issue.record("Reset working copy is not a valid normalized notebook"); return
            }
            #expect(kernelspec["name"] as? String == "python", "Starter must be normalized to Python (Pyodide) kernel.")
            // Sanity: starter contains the original markdown cell content
            let resetText = String(data: afterReset, encoding: .utf8) ?? ""
            #expect(
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
    }

    /// The reset must NOT delete past submissions — they remain on disk
    /// and in the DB for instructor review.  Only the live working-copy
    /// notebook is overwritten.
    @Test func resetStudentNotebookDoesNotTouchPriorSubmissions() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            let setup = try await arInsertSetup(id: "setup_reset_keep_subs", on: app)
            try await arAttachStarterNotebook(
                to: setup,
                bytes: Data(#"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#.utf8), on: app
            )
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_reset_keep_subs", title: "Lab", isOpen: true, on: app
            )
            let assignmentID = assignment.publicID
            let student = try await arInsertStudent(username: "reset_student_keep_subs", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            let studentUUID = try student.requireID()

            try await arInsertSubmission(
                id: "sub_kept_1",
                testSetupID: "setup_reset_keep_subs",
                userID: studentUUID, on: app
            )

            try await app.asyncTest(
                .POST,
                "/instructor/\(assignmentID)/students/\(studentUUID.uuidString)/reset-notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                }
            )

            let surviving = try await APISubmission.find("sub_kept_1", on: app.db)
            #expect(surviving != nil, "Prior submission must remain after notebook reset.")

        }
    }

    @Test func resetStudentNotebookRejectsUnenrolledStudent() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            let setup = try await arInsertSetup(id: "setup_reset_unenrolled", on: app)
            try await arAttachStarterNotebook(
                to: setup,
                bytes: Data(#"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#.utf8), on: app
            )
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_reset_unenrolled", title: "Lab", isOpen: true, on: app
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
                    #expect(res.status == .notFound)
                }
            )

        }
    }
    // MARK: - GET /:courseCode/students/:urlToken/submissions

    /// The dashboard roster lists every enrolled user (students, plus
    /// instructors/admins enrolled for testing).  Clicking any of them used
    /// to 404 unless the target had role == "student".  Now any enrolled
    /// user's course-scoped submissions are viewable, and the row appears
    /// once-per-assignment with a link to the latest submission.
    @Test func courseStudentSubmissionsPageWorksForEnrolledInstructor() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)

            // Enroll a second instructor in the same course and give them a submission.
            let otherInstructor = try await arInsertUser(
                username: "other_instructor",
                role: "instructor",
                displayName: "Other Instructor", on: app
            )
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            try await APICourseEnrollment(
                userID: try otherInstructor.requireID(),
                courseID: courseID
            ).save(on: app.db)

            _ = try await arInsertSetup(id: "instr_view_setup", on: app)
            _ = try await arInsertAssignment(
                testSetupID: "instr_view_setup",
                title: "Visible Assignment",
                isOpen: true, on: app
            )
            _ = try await arInsertSubmission(
                id: "instr_view_sub",
                testSetupID: "instr_view_setup",
                userID: try otherInstructor.requireID(), on: app
            )

            let url = "/TEST101/students/\(try otherInstructor.requireURLToken())/submissions"
            try await app.asyncTest(
                .GET, url,
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "Course-scoped submissions page must render for an enrolled non-student")
                    #expect(
                        res.body.string.contains("Visible Assignment"),
                        "Grouped page must show the assignment title row for this student")
                    #expect(
                        res.body.string.contains("instr_view_sub"),
                        "Latest-submission link should include the submission ID")
                })

        }
    }

    /// #556: the old `/students/<username>/...` URL shape no longer routes
    /// after the switch to opaque `urlToken`s.  Bookmarks against the
    /// legacy URL must 404 cleanly instead of resolving by username — that
    /// would defeat the privacy goal (usernames in logs / Referer headers).
    @Test func courseStudentSubmissionsPage404sForLegacyUsernameURL() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)

            let student = try await arInsertStudent(username: "legacy_url_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)

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
                    #expect(
                        res.status == .notFound,
                        "Legacy `/students/<username>` URL must 404 — only the urlToken shape is valid")
                })

        }
    }

    /// Non-enrolled users (in any role) still 404 — the page is course-scoped
    /// and must not leak submissions for users outside the active course.
    @Test func courseStudentSubmissionsPage404sForNonEnrolledUser() async throws {
        try await withAssignmentRoutesApp { app in
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)

            let stranger = try await arInsertUser(
                username: "stranger_user",
                role: "student",
                displayName: "Stranger", on: app
            )

            let url = "/TEST101/students/\(try stranger.requireURLToken())/submissions"
            try await app.asyncTest(
                .GET, url,
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound, "Non-enrolled user must 404 — enrollment is the only access gate")
                })

        }
    }
}
