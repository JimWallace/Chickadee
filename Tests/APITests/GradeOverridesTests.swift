// Tests/APITests/GradeOverridesTests.swift
//
// Coverage for the per-student grade override feature surfaced on the
// grouped /:courseCode/students/:urlToken/submissions page.
//
//  * Override upsert (POST grade-override)        → one row, percent stored.
//  * Override upsert (overwrite)                  → row updated, no duplicate.
//  * Override delete                              → row gone.
//  * Out-of-range percent is rejected            → no row written.
//  * Setting an override re-flags the student's results for BrightSpace sync.
//  * Grouped page renders the override value + "overridden" tag.

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct GradeOverridesTests {

    // MARK: - Upsert

    @Test func overridePostCreatesAndUpdatesRow() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            let student = try await arInsertStudent(username: "ovr_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            try await arInsertSetup(id: "ovr_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "ovr_setup", title: "Override me", isOpen: true, on: app
            )

            try await app.asyncTest(
                .POST,
                "/TEST101/students/\(try student.requireURLToken())/assignments/\(assignment.publicID)/grade-override",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["_csrf": csrf, "overridePercent": "85", "note": "Regraded by hand"],
                        as: .urlEncodedForm
                    )
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                }
            )

            let saved = try await APIGradeOverride.query(on: app.db)
                .filter(\.$testSetupID == "ovr_setup")
                .filter(\.$userID == (try student.requireID()))
                .all()
            #expect(saved.count == 1, "Upsert must create exactly one row")
            #expect(saved.first?.overridePercent == 85)
            #expect(saved.first?.note == "Regraded by hand")

            // Second POST updates in place.
            try await app.asyncTest(
                .POST,
                "/TEST101/students/\(try student.requireURLToken())/assignments/\(assignment.publicID)/grade-override",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["_csrf": csrf, "overridePercent": "50", "note": ""],
                        as: .urlEncodedForm
                    )
                },
                afterResponse: { _ in }
            )
            let updated = try await APIGradeOverride.query(on: app.db)
                .filter(\.$testSetupID == "ovr_setup")
                .filter(\.$userID == (try student.requireID()))
                .all()
            #expect(updated.count == 1, "Second POST must not create a duplicate")
            #expect(updated.first?.overridePercent == 50)
            #expect(updated.first?.note == nil, "Empty note must clear the note field")
        }
    }

    // MARK: - Delete

    @Test func overrideDeleteRemovesRow() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            let student = try await arInsertStudent(username: "ovr_delete_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            try await arInsertSetup(id: "ovr_delete_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "ovr_delete_setup", title: "Removable override", isOpen: true, on: app
            )

            try await APIGradeOverride(
                testSetupID: "ovr_delete_setup",
                userID: try student.requireID(),
                overridePercent: 70
            ).save(on: app.db)

            try await app.asyncTest(
                .POST,
                "/TEST101/students/\(try student.requireURLToken())/assignments/\(assignment.publicID)/grade-override/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                }
            )

            let remaining = try await APIGradeOverride.query(on: app.db)
                .filter(\.$testSetupID == "ovr_delete_setup")
                .count()
            #expect(remaining == 0, "Delete must remove the row")
        }
    }

    // MARK: - Validation

    @Test func overrideRejectsOutOfRangePercent() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            let student = try await arInsertStudent(username: "ovr_invalid_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            try await arInsertSetup(id: "ovr_invalid_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "ovr_invalid_setup", title: "Bad input", isOpen: true, on: app
            )

            try await app.asyncTest(
                .POST,
                "/TEST101/students/\(try student.requireURLToken())/assignments/\(assignment.publicID)/grade-override",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["_csrf": csrf, "overridePercent": "150"],
                        as: .urlEncodedForm
                    )
                },
                afterResponse: { res in
                    #expect(res.status != .seeOther, "Out-of-range percent must not succeed")
                }
            )

            let count = try await APIGradeOverride.query(on: app.db)
                .filter(\.$testSetupID == "ovr_invalid_setup")
                .count()
            #expect(count == 0, "Rejected override must not write a row")
        }
    }

    // MARK: - BrightSpace re-sync flag

    @Test func settingOverrideReflagsResultsForSync() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            let student = try await arInsertStudent(username: "ovr_sync_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            try await arInsertSetup(id: "ovr_sync_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "ovr_sync_setup", title: "Synced", isOpen: true, on: app
            )
            _ = try await arInsertSubmission(
                id: "sub_ovr_sync", testSetupID: "ovr_sync_setup",
                userID: try student.requireID(), on: app
            )
            let result = APIResult(
                id: "res_ovr_sync",
                submissionID: "sub_ovr_sync",
                collectionJSON: #"{"earnedPoints":1,"totalPoints":4,"passCount":1,"totalTests":4}"#
            )
            result.brightspaceSyncPending = false
            try await result.save(on: app.db)

            try await app.asyncTest(
                .POST,
                "/TEST101/students/\(try student.requireURLToken())/assignments/\(assignment.publicID)/grade-override",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["_csrf": csrf, "overridePercent": "100"],
                        as: .urlEncodedForm
                    )
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                }
            )

            let after = try await APIResult.find("res_ovr_sync", on: app.db)
            #expect(after?.brightspaceSyncPending == true, "Override must re-flag the result for BrightSpace sync")
            #expect(after?.brightspacePendingSince != nil)
        }
    }

    // MARK: - Page rendering

    @Test func groupedPageShowsOverrideValueAndTag() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)

            let student = try await arInsertStudent(username: "ovr_render_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            try await arInsertSetup(id: "ovr_render_setup", on: app)
            _ = try await arInsertAssignment(
                testSetupID: "ovr_render_setup", title: "Rendered Lab", isOpen: true, on: app
            )
            try await APIGradeOverride(
                testSetupID: "ovr_render_setup",
                userID: try student.requireID(),
                overridePercent: 42
            ).save(on: app.db)

            try await app.asyncTest(
                .GET, "/TEST101/students/\(try student.requireURLToken())/submissions",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("42%"), "Override value must be shown as the grade")
                    #expect(body.contains("overridden"), "Overridden grade must carry the tag")
                }
            )
        }
    }
}
