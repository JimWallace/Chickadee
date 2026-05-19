// Tests/APITests/AssignmentExtensionsTests.swift
//
// Coverage for the per-student deadline extension feature introduced
// alongside the grouped /:courseCode/students/:urlToken/submissions page.
//
//  * Extension upsert (POST extension)            → row exists with new date.
//  * Extension upsert (overwrite)                 → row updated, no duplicate.
//  * Extension delete                             → row gone.
//  * isAssignmentEffectivelyOpen(for:on:) gate    → respects extension.
//  * Scoped retest (one student × one assignment) → flips only that student.

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import chickadee_server

@Suite struct AssignmentExtensionsTests {

    // MARK: - Extension upsert

    @Test func extensionPostCreatesAndUpdatesRow() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            let student = try await arInsertStudent(username: "ext_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)

            try await arInsertSetup(id: "ext_setup", on: app)
            let pastDeadline = Date().addingTimeInterval(-3_600)  // 1h ago
            let assignment = try await arInsertAssignment(
                testSetupID: "ext_setup",
                title: "Closed by deadline",
                isOpen: true,
                dueAt: pastDeadline, on: app
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
                "/TEST101/students/\(try student.requireURLToken())/assignments/\(assignment.publicID)/extension",
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
                    #expect(res.status == .seeOther)
                }
            )

            let saved = try await APIAssignmentExtension.query(on: app.db)
                .filter(\.$assignmentID == (try assignment.requireID()))
                .filter(\.$userID == (try student.requireID()))
                .all()
            #expect(saved.count == 1, "Upsert must create exactly one row")
            #expect(saved.first?.note == "Conference travel")

            // Second POST updates in place.
            let further = Date().addingTimeInterval(172_800)
            let furtherInput = fmt.string(from: further)
            try await app.asyncTest(
                .POST,
                "/TEST101/students/\(try student.requireURLToken())/assignments/\(assignment.publicID)/extension",
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
            #expect(updated.count == 1, "Second POST must not create a duplicate")
            #expect(updated.first?.note == nil, "Empty note must clear the note field")

        }
    }

    // MARK: - Extension delete

    @Test func extensionDeleteRemovesRow() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            let student = try await arInsertStudent(username: "ext_delete_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            try await arInsertSetup(id: "ext_delete_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "ext_delete_setup",
                title: "Removable extension",
                isOpen: true, on: app
            )

            let row = APIAssignmentExtension(
                assignmentID: try assignment.requireID(),
                userID: try student.requireID(),
                extendedDueAt: Date().addingTimeInterval(86_400)
            )
            try await row.save(on: app.db)

            try await app.asyncTest(
                .POST,
                "/TEST101/students/\(try student.requireURLToken())/assignments/\(assignment.publicID)/extension/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                }
            )

            let remaining = try await APIAssignmentExtension.query(on: app.db)
                .filter(\.$assignmentID == (try assignment.requireID()))
                .count()
            #expect(remaining == 0, "Delete must remove the row")

        }
    }

    // MARK: - Deadline gate behaviour

    @Test func effectiveDueAtUsesExtensionWhenLater() async throws {
        try await withAssignmentRoutesApp { app in
            try await arInsertSetup(id: "effective_setup", on: app)
            let baseline = Date().addingTimeInterval(-3_600)  // 1h ago
            let assignment = try await arInsertAssignment(
                testSetupID: "effective_setup",
                title: "Past assignment",
                isOpen: true,
                dueAt: baseline, on: app
            )
            let student = try await arInsertStudent(username: "effective_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)

            // No extension yet — effectiveDueAt == baseline.
            let withoutExt = try await effectiveDueAt(for: assignment, user: student, on: app.db)
            #expect(withoutExt == baseline)

            // Add an extension into the future — that's what gets returned.
            let future = Date().addingTimeInterval(86_400)
            try await APIAssignmentExtension(
                assignmentID: try assignment.requireID(),
                userID: try student.requireID(),
                extendedDueAt: future
            ).save(on: app.db)
            let withExt = try #require(
                try await effectiveDueAt(for: assignment, user: student, on: app.db))
            #expect(abs(withExt.timeIntervalSinceReferenceDate - future.timeIntervalSinceReferenceDate) < 1)

            // Sanity: the per-user gate now reports open.
            let openForExtended = try await isAssignmentEffectivelyOpen(
                assignment, for: student, on: app.db
            )
            #expect(
                openForExtended,
                "Student with an active extension must see the assignment as open")

            // A peer without an extension still hits the closed gate.
            let peer = try await arInsertStudent(username: "effective_peer", on: app)
            try await arEnrollStudentInTestCourse(peer, on: app)
            let openForPeer = try await isAssignmentEffectivelyOpen(
                assignment, for: peer, on: app.db
            )
            #expect(openForPeer == false, "Other students must not benefit from someone else's extension")

        }
    }

    // MARK: - Scoped retest

    @Test func scopedRetestFlipsOnlyThisStudentsSubmissions() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            try await arInsertSetup(id: "scoped_retest_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "scoped_retest_setup",
                title: "Scoped retest",
                isOpen: true, on: app
            )

            let targetStudent = try await arInsertStudent(username: "scoped_target", on: app)
            try await arEnrollStudentInTestCourse(targetStudent, on: app)
            let otherStudent = try await arInsertStudent(username: "scoped_other", on: app)
            try await arEnrollStudentInTestCourse(otherStudent, on: app)

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
                "/TEST101/students/\(try targetStudent.requireURLToken())/assignments/\(assignment.publicID)/retest",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                }
            )

            let targetAfter = try await APISubmission.find("sub_scoped_target", on: app.db)
            #expect(targetAfter?.status == "pending")
            #expect(targetAfter?.workerID == nil)
            #expect(targetAfter?.retestedAt != nil)

            let otherAfter = try await APISubmission.find("sub_scoped_other", on: app.db)
            #expect(otherAfter?.status == "complete", "Scoped retest must not touch other students' submissions")
            #expect(otherAfter?.retestedAt == nil)

        }
    }

    // MARK: - Grouped page rendering

    @Test func groupedPageShowsAllPublishedAssignmentsIncludingEmptyOnes() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)

            try await arInsertSetup(id: "grp_setup_1", on: app)
            _ = try await arInsertAssignment(
                testSetupID: "grp_setup_1", title: "First Lab", isOpen: true, on: app
            )
            try await arInsertSetup(id: "grp_setup_2", on: app)
            _ = try await arInsertAssignment(
                testSetupID: "grp_setup_2", title: "Second Lab", isOpen: true, on: app
            )

            let student = try await arInsertStudent(username: "grp_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)

            // Submit on the first assignment only — the second must render as
            // "No submissions yet" rather than be hidden.
            _ = try await arInsertSubmission(
                id: "sub_grp_1",
                testSetupID: "grp_setup_1",
                userID: try student.requireID(), on: app
            )

            try await app.asyncTest(
                .GET, "/TEST101/students/\(try student.requireURLToken())/submissions",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("First Lab"), "Submitted assignment must appear")
                    #expect(body.contains("Second Lab"), "Empty assignment must also appear")
                    #expect(
                        body.contains("No submissions yet"),
                        "Empty row must surface the friendly placeholder"
                    )
                    #expect(
                        body.contains("sub_grp_1"),
                        "Latest submission link should reference the submission ID"
                    )
                }
            )

        }
    }
}
