// Tests/APITests/AssignmentSubmissionsSparklineTests.swift
//
// Render tests for the server-rendered sparklines on the instructor
// assignment-submissions page (GET /instructor/:assignmentID/submissions).
// Avg Attempts/Student and Median Grade draw a fixed distribution chart;
// Submissions is a cyclable card carrying pre-rendered 24h/7d/30d windows the
// browser swaps on click.  All are server-rendered from pre-normalized bar
// heights; the charts are omitted when there is no activity.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized)
struct AssignmentSubmissionsSparklineTests {

    @Test func submissionsPageRendersDistributionSparklines() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)

            let student = try await arInsertStudent(username: "spark_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            try await arInsertSetup(id: "spark_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "spark_setup", title: "Sparkline Lab", isOpen: true, on: app)
            _ = try await arInsertSubmission(
                id: "sub_spark", testSetupID: "spark_setup",
                userID: try student.requireID(), on: app)
            // 3/4 → 75% → lands in the 70–79% grade bin.
            let result = APIResult(
                id: "res_spark",
                submissionID: "sub_spark",
                collectionJSON: #"{"earnedPoints":3,"totalPoints":4,"passCount":3,"totalTests":4}"#
            )
            try await result.save(on: app.db)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/submissions",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    // Server-rendered sparkline scaffolding (no JS needed).
                    #expect(body.contains("diagnostic-spark"), "sparkline container must render")
                    #expect(body.contains("--bar-h:"), "bars carry a normalized height")
                    // Attempts distribution tooltip: one student, one attempt.
                    #expect(body.contains("1 attempt: 1 student"), "attempts distribution bins by count")
                    // Accessible captions for the fixed distribution cards.
                    #expect(body.contains("Grade distribution across 1 graded student"))
                    #expect(body.contains("Submission attempts per student"))
                    // Submissions card is cyclable: all three windows render server-side.
                    #expect(body.contains("data-subm-trend"), "Submissions card is cyclable")
                    #expect(body.contains("data-subm-window=\"24h\""))
                    #expect(body.contains("data-subm-window=\"7d\""))
                    #expect(body.contains("data-subm-window=\"30d\""))
                }
            )
        }
    }

    @Test func submissionsPageOmitsSparklineWithoutActivity() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)

            let student = try await arInsertStudent(username: "spark_none", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            try await arInsertSetup(id: "spark_none_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "spark_none_setup", title: "No Subs Lab", isOpen: true, on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/submissions",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    // The headline cards still render…
                    #expect(body.contains("Median Grade"))
                    #expect(body.contains("Avg Attempts/Student"))
                    // …but with no submissions there is no distribution to chart,
                    // and the Submissions card stays a plain number (not cyclable).
                    // (`data-subm-trend` also appears in the always-present cycling
                    // script, so key off the per-window markup the card alone emits.)
                    #expect(!body.contains("diagnostic-spark"), "no sparkline without activity")
                    #expect(!body.contains("data-subm-window="), "Submissions card not cyclable without activity")
                }
            )
        }
    }
}
