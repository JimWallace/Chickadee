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

@testable import APIServer

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

    /// The real-world failure: the deadline sweep flips `isOpen` to false at
    /// the deadline, so the per-user gate must still report open for a student
    /// holding an active extension on an auto-closed assignment.
    @Test func effectiveOpenHonorsExtensionAfterAutoClose() async throws {
        try await withAssignmentRoutesApp { app in
            try await arInsertSetup(id: "autoclosed_setup", on: app)
            // Auto-closed at its deadline: isOpen=false, due date in the past.
            let assignment = try await arInsertAssignment(
                testSetupID: "autoclosed_setup",
                title: "Auto-closed",
                isOpen: false,
                dueAt: Date().addingTimeInterval(-3_600), on: app
            )
            let student = try await arInsertStudent(username: "autoclosed_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)

            // No extension yet — auto-closed assignment is closed for everyone.
            let beforeExt = try await isAssignmentEffectivelyOpen(assignment, for: student, on: app.db)
            #expect(beforeExt == false, "Auto-closed assignment with no extension stays closed")

            try await APIAssignmentExtension(
                assignmentID: try assignment.requireID(),
                userID: try student.requireID(),
                extendedDueAt: Date().addingTimeInterval(86_400)
            ).save(on: app.db)

            let afterExt = try await isAssignmentEffectivelyOpen(assignment, for: student, on: app.db)
            #expect(afterExt, "An active extension reopens an auto-closed assignment for that student")

            let peer = try await arInsertStudent(username: "autoclosed_peer", on: app)
            try await arEnrollStudentInTestCourse(peer, on: app)
            let peerOpen = try await isAssignmentEffectivelyOpen(assignment, for: peer, on: app.db)
            #expect(peerOpen == false, "A peer without an extension stays closed")
        }
    }

    // MARK: - Per-user open decision (pure logic)

    @Test func openForUserCoversDeadlineAndExtensionCases() {
        let now = Date()
        let past = now.addingTimeInterval(-3_600)
        let future = now.addingTimeInterval(3_600)

        // Open, deadline still ahead → open for everyone.
        #expect(
            isAssignmentOpenForUser(
                isOpen: true, overrideActive: false,
                baselineDueAt: future, effectiveDueAt: future, now: now))
        // Open, past deadline, no extension → closed.
        #expect(
            isAssignmentOpenForUser(
                isOpen: true, overrideActive: false,
                baselineDueAt: past, effectiveDueAt: past, now: now) == false)
        // Open, past deadline, class-wide override → open.
        #expect(
            isAssignmentOpenForUser(
                isOpen: true, overrideActive: true,
                baselineDueAt: past, effectiveDueAt: past, now: now))
        // Auto-closed at deadline, extension into the future → open for this user.
        #expect(
            isAssignmentOpenForUser(
                isOpen: false, overrideActive: false,
                baselineDueAt: past, effectiveDueAt: future, now: now))
        // Auto-closed at deadline, no live extension → closed.
        #expect(
            isAssignmentOpenForUser(
                isOpen: false, overrideActive: false,
                baselineDueAt: past, effectiveDueAt: past, now: now) == false)
        // Manual close *before* the deadline is deliberate — an extension does
        // not reopen it.
        #expect(
            isAssignmentOpenForUser(
                isOpen: false, overrideActive: false,
                baselineDueAt: future, effectiveDueAt: future.addingTimeInterval(86_400),
                now: now) == false)
        // No deadline at all, open → open.
        #expect(
            isAssignmentOpenForUser(
                isOpen: true, overrideActive: false,
                baselineDueAt: nil, effectiveDueAt: nil, now: now))
    }

    @Test func futureOpenDateGatesAccessUntilItPasses() {
        let now = Date()
        let past = now.addingTimeInterval(-3_600)
        let future = now.addingTimeInterval(3_600)

        // Open, no deadline, but the open date is still ahead → closed for all.
        #expect(
            isAssignmentOpenForUser(
                isOpen: true, overrideActive: false,
                baselineDueAt: nil, effectiveDueAt: nil,
                startsAt: future, now: now) == false)
        // A future open date wins even over an active deadline extension.
        #expect(
            isAssignmentOpenForUser(
                isOpen: false, overrideActive: false,
                baselineDueAt: past, effectiveDueAt: future.addingTimeInterval(86_400),
                startsAt: future, now: now) == false)
        // Open date already passed → behaves exactly as if unset (open).
        #expect(
            isAssignmentOpenForUser(
                isOpen: true, overrideActive: false,
                baselineDueAt: future, effectiveDueAt: future,
                startsAt: past, now: now))
        // nil open date is the existing behaviour (open immediately).
        #expect(
            isAssignmentOpenForUser(
                isOpen: true, overrideActive: false,
                baselineDueAt: future, effectiveDueAt: future,
                startsAt: nil, now: now))
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
