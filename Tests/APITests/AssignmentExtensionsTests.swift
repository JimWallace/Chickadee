// Tests/APITests/AssignmentExtensionsTests.swift
//
// Coverage for the per-student deadline extension feature introduced
// alongside the grouped /:courseCode/students/:username/submissions page.
//
//  * Extension upsert (POST extension)            → row exists with new date.
//  * Extension upsert (overwrite)                 → row updated, no duplicate.
//  * Extension delete                             → row gone.
//  * isAssignmentEffectivelyOpen(for:on:) gate    → respects extension.
//  * Scoped retest (one student × one assignment) → flips only that student.

import Core
import Fluent
import Foundation
import XCTVapor
import XCTest

@testable import chickadee_server

final class AssignmentExtensionsTests: AssignmentRoutesTestCase {

    // MARK: - Extension upsert

    func testExtensionPostCreatesAndUpdatesRow() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        let student = try await insertStudent(username: "ext_student")
        try await enrollStudentInTestCourse(student)

        try await insertSetup(id: "ext_setup")
        let pastDeadline = Date().addingTimeInterval(-3_600)  // 1h ago
        let assignment = try await insertAssignment(
            testSetupID: "ext_setup",
            title: "Closed by deadline",
            isOpen: true,
            dueAt: pastDeadline
        )

        // Pick a date 1 day in the future, formatted for `datetime-local`.
        let future = Date().addingTimeInterval(86_400)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "America/Toronto")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let futureInput = fmt.string(from: future)

        try await app.asyncTest(
            .POST,
            "/TEST101/students/ext_student/assignments/\(assignment.publicID)/extension",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                try req.content.encode(
                    [
                        "_csrf": csrf,
                        "extendedDueAt": futureInput,
                        "note": "Conference travel",
                    ],
                    as: .urlEncodedForm
                )
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
            }
        )

        let saved = try await APIAssignmentExtension.query(on: app.db)
            .filter(\.$assignmentID == (try assignment.requireID()))
            .filter(\.$userID == (try student.requireID()))
            .all()
        XCTAssertEqual(saved.count, 1, "Upsert must create exactly one row")
        XCTAssertEqual(saved.first?.note, "Conference travel")

        // Second POST updates in place.
        let further = Date().addingTimeInterval(172_800)
        let furtherInput = fmt.string(from: further)
        try await app.asyncTest(
            .POST,
            "/TEST101/students/ext_student/assignments/\(assignment.publicID)/extension",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                try req.content.encode(
                    ["_csrf": csrf, "extendedDueAt": furtherInput, "note": ""],
                    as: .urlEncodedForm
                )
            },
            afterResponse: { _ in }
        )
        let updated = try await APIAssignmentExtension.query(on: app.db)
            .filter(\.$assignmentID == (try assignment.requireID()))
            .filter(\.$userID == (try student.requireID()))
            .all()
        XCTAssertEqual(updated.count, 1, "Second POST must not create a duplicate")
        XCTAssertNil(updated.first?.note, "Empty note must clear the note field")
    }

    // MARK: - Extension delete

    func testExtensionDeleteRemovesRow() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        let student = try await insertStudent(username: "ext_delete_student")
        try await enrollStudentInTestCourse(student)
        try await insertSetup(id: "ext_delete_setup")
        let assignment = try await insertAssignment(
            testSetupID: "ext_delete_setup",
            title: "Removable extension",
            isOpen: true
        )

        let row = APIAssignmentExtension(
            assignmentID: try assignment.requireID(),
            userID: try student.requireID(),
            extendedDueAt: Date().addingTimeInterval(86_400)
        )
        try await row.save(on: app.db)

        try await app.asyncTest(
            .POST,
            "/TEST101/students/ext_delete_student/assignments/\(assignment.publicID)/extension/delete",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
            }
        )

        let remaining = try await APIAssignmentExtension.query(on: app.db)
            .filter(\.$assignmentID == (try assignment.requireID()))
            .count()
        XCTAssertEqual(remaining, 0, "Delete must remove the row")
    }

    // MARK: - Deadline gate behaviour

    func testEffectiveDueAtUsesExtensionWhenLater() async throws {
        try await insertSetup(id: "effective_setup")
        let baseline = Date().addingTimeInterval(-3_600)  // 1h ago
        let assignment = try await insertAssignment(
            testSetupID: "effective_setup",
            title: "Past assignment",
            isOpen: true,
            dueAt: baseline
        )
        let student = try await insertStudent(username: "effective_student")
        try await enrollStudentInTestCourse(student)

        // No extension yet — effectiveDueAt == baseline.
        let withoutExt = try await effectiveDueAt(for: assignment, user: student, on: app.db)
        XCTAssertEqual(withoutExt, baseline)

        // Add an extension into the future — that's what gets returned.
        let future = Date().addingTimeInterval(86_400)
        try await APIAssignmentExtension(
            assignmentID: try assignment.requireID(),
            userID: try student.requireID(),
            extendedDueAt: future
        ).save(on: app.db)
        let withExt = try await effectiveDueAt(for: assignment, user: student, on: app.db)
        XCTAssertNotNil(withExt)
        XCTAssertEqual(withExt!.timeIntervalSinceReferenceDate, future.timeIntervalSinceReferenceDate, accuracy: 1)

        // Sanity: the per-user gate now reports open.
        let openForExtended = try await isAssignmentEffectivelyOpen(
            assignment, for: student, on: app.db
        )
        XCTAssertTrue(
            openForExtended,
            "Student with an active extension must see the assignment as open")

        // A peer without an extension still hits the closed gate.
        let peer = try await insertStudent(username: "effective_peer")
        try await enrollStudentInTestCourse(peer)
        let openForPeer = try await isAssignmentEffectivelyOpen(
            assignment, for: peer, on: app.db
        )
        XCTAssertFalse(openForPeer, "Other students must not benefit from someone else's extension")
    }

    // MARK: - Scoped retest

    func testScopedRetestFlipsOnlyThisStudentsSubmissions() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        try await insertSetup(id: "scoped_retest_setup")
        let assignment = try await insertAssignment(
            testSetupID: "scoped_retest_setup",
            title: "Scoped retest",
            isOpen: true
        )

        let targetStudent = try await insertStudent(username: "scoped_target")
        try await enrollStudentInTestCourse(targetStudent)
        let otherStudent = try await insertStudent(username: "scoped_other")
        try await enrollStudentInTestCourse(otherStudent)

        let targetSubmission = APISubmission(
            id: "sub_scoped_target",
            testSetupID: "scoped_retest_setup",
            zipPath: app.submissionsDirectory + "sub_scoped_target.zip",
            attemptNumber: 1,
            status: "complete",
            userID: targetStudent.id
        )
        targetSubmission.workerID = "worker-x"
        try await targetSubmission.save(on: app.db)

        let otherSubmission = APISubmission(
            id: "sub_scoped_other",
            testSetupID: "scoped_retest_setup",
            zipPath: app.submissionsDirectory + "sub_scoped_other.zip",
            attemptNumber: 1,
            status: "complete",
            userID: otherStudent.id
        )
        try await otherSubmission.save(on: app.db)

        try await app.asyncTest(
            .POST,
            "/TEST101/students/scoped_target/assignments/\(assignment.publicID)/retest",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
            }
        )

        let targetAfter = try await APISubmission.find("sub_scoped_target", on: app.db)
        XCTAssertEqual(targetAfter?.status, "pending")
        XCTAssertNil(targetAfter?.workerID)
        XCTAssertNotNil(targetAfter?.retestedAt)

        let otherAfter = try await APISubmission.find("sub_scoped_other", on: app.db)
        XCTAssertEqual(
            otherAfter?.status, "complete",
            "Scoped retest must not touch other students' submissions")
        XCTAssertNil(otherAfter?.retestedAt)
    }

    // MARK: - Grouped page rendering

    func testGroupedPageShowsAllPublishedAssignmentsIncludingEmptyOnes() async throws {
        let cookie = try await loginAsInstructor()

        try await insertSetup(id: "grp_setup_1")
        _ = try await insertAssignment(
            testSetupID: "grp_setup_1", title: "First Lab", isOpen: true
        )
        try await insertSetup(id: "grp_setup_2")
        _ = try await insertAssignment(
            testSetupID: "grp_setup_2", title: "Second Lab", isOpen: true
        )

        let student = try await insertStudent(username: "grp_student")
        try await enrollStudentInTestCourse(student)

        // Submit on the first assignment only — the second must render as
        // "No submissions yet" rather than be hidden.
        _ = try await insertSubmission(
            id: "sub_grp_1",
            testSetupID: "grp_setup_1",
            userID: try student.requireID()
        )

        try await app.asyncTest(
            .GET, "/TEST101/students/grp_student/submissions",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let body = res.body.string
                XCTAssertTrue(body.contains("First Lab"), "Submitted assignment must appear")
                XCTAssertTrue(body.contains("Second Lab"), "Empty assignment must also appear")
                XCTAssertTrue(
                    body.contains("No submissions yet"),
                    "Empty row must surface the friendly placeholder"
                )
                XCTAssertTrue(
                    body.contains("sub_grp_1"),
                    "Latest submission link should reference the submission ID"
                )
            }
        )
    }
}
