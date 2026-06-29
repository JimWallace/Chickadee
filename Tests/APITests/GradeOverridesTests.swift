// Tests/APITests/GradeOverridesTests.swift
//
// Coverage for the per-student grade override feature, surfaced on both the
// grouped /:courseCode/students/:urlToken/submissions page and the
// per-assignment /instructor/:assignmentID/submissions roster.
//
//  * Override upsert (POST grade-override)        → one row, percent stored.
//  * Override upsert (overwrite)                  → row updated, no duplicate.
//  * Override delete                              → row gone.
//  * Out-of-range percent is rejected            → no row written.
//  * Setting an override re-flags the student's results for BrightSpace sync.
//  * Grouped page renders the override value + "overridden" tag.
//  * Instructor roster: set / update / delete via the UUID-keyed endpoint,
//    out-of-range + unenrolled-student rejection, control rendered in-page.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

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

    // MARK: - Instructor roster + median

    @Test func overrideReplacesGradeOnInstructorRosterAndMedian() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)

            let student = try await arInsertStudent(username: "ovr_roster_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            try await arInsertSetup(id: "ovr_roster_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "ovr_roster_setup", title: "Roster Lab", isOpen: true, on: app
            )
            _ = try await arInsertSubmission(
                id: "sub_ovr_roster", testSetupID: "ovr_roster_setup",
                userID: try student.requireID(), on: app
            )
            // Runner grade 25% (1/4) — should be replaced by the 90% override.
            let result = APIResult(
                id: "res_ovr_roster",
                submissionID: "sub_ovr_roster",
                collectionJSON: #"{"earnedPoints":1,"totalPoints":4,"passCount":1,"totalTests":4}"#
            )
            try await result.save(on: app.db)
            try await APIGradeOverride(
                testSetupID: "ovr_roster_setup",
                userID: try student.requireID(),
                overridePercent: 90
            ).save(on: app.db)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/submissions",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("90%"), "Override grade must appear on the roster")
                    #expect(body.contains("overridden"), "Override must carry the tag")
                    #expect(!body.contains("25%"), "Runner grade must be replaced by the override")
                    // Median metric is computed from the (overridden) best grade.
                    #expect(body.contains("Median Grade"))
                }
            )
        }
    }

    // MARK: - Grades CSV export

    @Test func overrideWithoutSubmissionAppearsInGradesCSV() async throws {
        // A student who never submitted but has a manual grade override must still
        // appear in the CSV with the override points, not a blank cell.
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let manifest = """
                {"schemaVersion":1,"requiredFiles":[],"testSuites":\
                [{"tier":"public","script":"t.sh","points":10}],"timeLimitSeconds":10}
                """
            let setup = APITestSetup(
                id: "ovr_nosub_setup",
                manifest: manifest,
                zipPath: app.testSetupsDirectory + "ovr_nosub_setup.zip",
                courseID: courseID
            )
            try await setup.save(on: app.db)
            _ = try await arInsertAssignment(
                testSetupID: "ovr_nosub_setup", title: "No-Sub Lab", isOpen: true, on: app
            )
            let student = try await arInsertStudent(username: "ovr_nosub_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            // Deliberately no submission — instructor sets an 80% manual override.
            try await APIGradeOverride(
                testSetupID: "ovr_nosub_setup",
                userID: try student.requireID(),
                overridePercent: 80
            ).save(on: app.db)

            try await app.asyncTest(
                .GET, "/instructor/grades.csv",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(
                        body.contains("8.0"),
                        "80% of 10 pts must export as 8.0 even when the student has no submission"
                    )
                })
        }
    }

    @Test func overrideAppliedToGradesCSVAsPoints() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)

            // Setup whose suite is worth 4 points, so a 50% override = 2.0 pts.
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let manifest = """
                {"schemaVersion":1,"requiredFiles":[],"testSuites":\
                [{"tier":"public","script":"t.sh","points":4}],"timeLimitSeconds":10}
                """
            let setup = APITestSetup(
                id: "ovr_csv_setup",
                manifest: manifest,
                zipPath: app.testSetupsDirectory + "ovr_csv_setup.zip",
                courseID: courseID
            )
            try await setup.save(on: app.db)
            let assignment = try await arInsertAssignment(
                testSetupID: "ovr_csv_setup", title: "CSV Lab", isOpen: true, on: app
            )
            _ = assignment
            let student = try await arInsertStudent(username: "ovr_csv_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            _ = try await arInsertSubmission(
                id: "sub_ovr_csv", testSetupID: "ovr_csv_setup",
                userID: try student.requireID(), on: app
            )
            let result = APIResult(
                id: "res_ovr_csv",
                submissionID: "sub_ovr_csv",
                collectionJSON: #"{"earnedPoints":4,"totalPoints":4,"passCount":4,"totalTests":4}"#
            )
            try await result.save(on: app.db)
            try await APIGradeOverride(
                testSetupID: "ovr_csv_setup",
                userID: try student.requireID(),
                overridePercent: 50
            ).save(on: app.db)

            try await app.asyncTest(
                .GET, "/instructor/grades.csv",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("2.0"), "Override (50% of 4 pts) must export as 2.0")
                    #expect(!body.contains("4.0"), "Runner points must be replaced by the override")
                }
            )
        }
    }

    // MARK: - Student submission page banner

    @Test func overrideBannerShownOnSubmissionPage() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrEnrollUser(student, on: app)
            try await wrInsertSetup(id: "ovr_subpage_setup", on: app)
            _ = try await wrInsertAssignment(
                testSetupID: "ovr_subpage_setup", title: "Sub Page Lab", isOpen: true, on: app
            )
            _ = try await wrInsertSubmission(
                id: "sub_ovr_page", testSetupID: "ovr_subpage_setup",
                userID: try student.requireID(), on: app
            )
            _ = try await wrInsertResult(
                submissionID: "sub_ovr_page",
                outcomes: [wrMakeOutcome(name: "t1", status: .pass)],
                on: app
            )
            try await APIGradeOverride(
                testSetupID: "ovr_subpage_setup",
                userID: try student.requireID(),
                overridePercent: 55
            ).save(on: app.db)

            try await app.asyncTest(
                .GET, "/submissions/sub_ovr_page",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("55%"), "Override grade must headline the submission page")
                    #expect(body.contains("overridden"), "Override must carry the tag")
                    #expect(body.contains("Autograded:"), "Autograde breakdown must be labelled")
                }
            )
        }
    }

    // MARK: - Instructor per-assignment roster: set / clear control
    //
    // The same (test_setup, user) override, now reachable from the
    // /instructor/:assignmentID/submissions roster keyed by the student's
    // UUID (mirrors the sibling reset-notebook action), in addition to the
    // grouped per-student page exercised above.

    @Test func rosterOverridePostCreatesAndUpdatesRow() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            let student = try await arInsertStudent(username: "roster_ovr_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            try await arInsertSetup(id: "roster_ovr_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "roster_ovr_setup", title: "Roster Override", isOpen: true, on: app
            )
            let studentUUID = try student.requireID()

            try await app.asyncTest(
                .POST,
                "/instructor/\(assignment.publicID)/students/\(studentUUID.uuidString)/grade-override",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["_csrf": csrf, "overridePercent": "88", "note": "Manual regrade"],
                        as: .urlEncodedForm
                    )
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(
                        res.headers.first(name: .location)
                            == "/instructor/\(assignment.publicID)/submissions",
                        "Default redirect lands back on the roster"
                    )
                }
            )

            let saved = try await APIGradeOverride.query(on: app.db)
                .filter(\.$testSetupID == "roster_ovr_setup")
                .filter(\.$userID == studentUUID)
                .all()
            #expect(saved.count == 1, "Upsert must create exactly one row")
            #expect(saved.first?.overridePercent == 88)
            #expect(saved.first?.note == "Manual regrade")

            // Second POST updates the same row in place.
            try await app.asyncTest(
                .POST,
                "/instructor/\(assignment.publicID)/students/\(studentUUID.uuidString)/grade-override",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf, "overridePercent": "60"], as: .urlEncodedForm)
                },
                afterResponse: { _ in }
            )
            let updated = try await APIGradeOverride.query(on: app.db)
                .filter(\.$testSetupID == "roster_ovr_setup")
                .filter(\.$userID == studentUUID)
                .all()
            #expect(updated.count == 1, "Second POST must not create a duplicate")
            #expect(updated.first?.overridePercent == 60)
        }
    }

    @Test func rosterOverrideDeleteRemovesRow() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            let student = try await arInsertStudent(username: "roster_ovr_del", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            try await arInsertSetup(id: "roster_ovr_del_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "roster_ovr_del_setup", title: "Roster Removable", isOpen: true, on: app
            )
            let studentUUID = try student.requireID()
            try await APIGradeOverride(
                testSetupID: "roster_ovr_del_setup", userID: studentUUID, overridePercent: 70
            ).save(on: app.db)

            try await app.asyncTest(
                .POST,
                "/instructor/\(assignment.publicID)/students/\(studentUUID.uuidString)/grade-override/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                }
            )

            let remaining = try await APIGradeOverride.query(on: app.db)
                .filter(\.$testSetupID == "roster_ovr_del_setup")
                .count()
            #expect(remaining == 0, "Delete must remove the row")
        }
    }

    @Test func rosterOverrideRejectsOutOfRangePercent() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            let student = try await arInsertStudent(username: "roster_ovr_bad", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            try await arInsertSetup(id: "roster_ovr_bad_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "roster_ovr_bad_setup", title: "Roster Bad", isOpen: true, on: app
            )
            let studentUUID = try student.requireID()

            try await app.asyncTest(
                .POST,
                "/instructor/\(assignment.publicID)/students/\(studentUUID.uuidString)/grade-override",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf, "overridePercent": "150"], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status != .seeOther, "Out-of-range percent must not succeed")
                }
            )
            let count = try await APIGradeOverride.query(on: app.db)
                .filter(\.$testSetupID == "roster_ovr_bad_setup")
                .count()
            #expect(count == 0, "Rejected override must not write a row")
        }
    }

    @Test func rosterOverrideRejectsUnenrolledStudent() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            // Real user, deliberately NOT enrolled in TEST101 — exercises the
            // enrollment gate rather than the "user missing" branch.
            let stranger = try await arInsertStudent(username: "roster_ovr_stranger", on: app)
            try await arInsertSetup(id: "roster_ovr_stranger_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "roster_ovr_stranger_setup", title: "Roster Stranger", isOpen: true, on: app
            )
            let strangerUUID = try stranger.requireID()

            try await app.asyncTest(
                .POST,
                "/instructor/\(assignment.publicID)/students/\(strangerUUID.uuidString)/grade-override",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf, "overridePercent": "80"], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                }
            )
            let count = try await APIGradeOverride.query(on: app.db)
                .filter(\.$testSetupID == "roster_ovr_stranger_setup")
                .count()
            #expect(count == 0, "Override for an unenrolled student must not be written")
        }
    }

    @Test func rosterRendersOverrideControl() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)

            let student = try await arInsertStudent(username: "roster_ctrl_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            try await arInsertSetup(id: "roster_ctrl_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "roster_ctrl_setup", title: "Roster Ctrl", isOpen: true, on: app
            )
            let studentUUID = try student.requireID()

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/submissions",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(
                        body.contains(
                            "/instructor/\(assignment.publicID)/students/\(studentUUID.uuidString)/grade-override"
                        ),
                        "Roster must render the per-student override form action"
                    )
                    #expect(body.contains("Override grade (%)"), "Override form must be present")
                }
            )
        }
    }
}
