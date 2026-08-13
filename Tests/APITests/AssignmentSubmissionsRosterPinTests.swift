// Tests/APITests/AssignmentSubmissionsRosterPinTests.swift
//
// Pins the VALUES the instructor assignment-submissions roster derives from
// the per-assignment submission history (#1382 item 6) — best grade across
// attempts, the latest-submission pick, the attempt count, and the derived
// metric cards — so the aggregate rewrite of the page's loaders cannot
// change a fold's meaning without a test noticing. Written and verified
// against the pre-aggregate loaders first.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized)
struct AssignmentSubmissionsRosterPinTests {

    @Test func rosterPinsGradeLatestCountAndMetricsAcrossAttempts() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)

            // Student A: three attempts at 40%, 80%, 20% — best 80, latest #3.
            let alice = try await arInsertStudent(username: "roster_alice", on: app)
            try await arEnrollStudentInTestCourse(alice, on: app)
            let aliceID = try alice.requireID()
            // Student B: one attempt at 60%.
            let bob = try await arInsertStudent(username: "roster_bob", on: app)
            try await arEnrollStudentInTestCourse(bob, on: app)
            let bobID = try bob.requireID()

            try await arInsertSetup(id: "roster_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "roster_setup", title: "Roster Lab", isOpen: true, on: app)

            for (index, percentPair) in [(2, 5), (4, 5), (1, 5)].enumerated() {
                let attempt = index + 1
                _ = try await arInsertSubmission(
                    id: "sub_roster_a\(attempt)", testSetupID: "roster_setup",
                    userID: aliceID, attemptNumber: attempt, on: app)
                let result = APIResult(
                    id: "res_roster_a\(attempt)", submissionID: "sub_roster_a\(attempt)")
                try await result.saveWithCollection(
                    json: #"{"passCount":\#(percentPair.0),"totalTests":\#(percentPair.1)}"#,
                    on: app.db)
            }
            _ = try await arInsertSubmission(
                id: "sub_roster_b1", testSetupID: "roster_setup",
                userID: bobID, attemptNumber: 1, on: app)
            let bobResult = APIResult(id: "res_roster_b1", submissionID: "sub_roster_b1")
            try await bobResult.saveWithCollection(
                json: #"{"passCount":3,"totalTests":5}"#, on: app.db)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/submissions",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(
                        body.contains("<td>80%"),
                        "A row's grade is the best across ALL attempts")
                    #expect(
                        !body.contains("<td>20%"),
                        "The latest attempt's lower grade must not displace the best")
                    #expect(
                        body.contains(#"/submissions/sub_roster_a3" class="submission-history-latest""#),
                        "The latest-submission link points at the newest attempt")
                    #expect(
                        body.contains("+2 more"),
                        "The history link counts every prior attempt")
                    #expect(
                        body.contains("<td>60%"),
                        "A single-attempt student's grade renders")
                    #expect(
                        body.contains(">2/2<"),
                        "Students Submitted counts distinct submitters over the roster")
                    #expect(
                        body.contains(">2.0<"),
                        "Avg attempts averages per submitted student: (3 + 1) / 2")
                    #expect(
                        body.contains(">70%<"),
                        "Median grade is the median of per-student bests: {80, 60} → 70")
                    #expect(
                        body.contains("3 attempts: 1 student"),
                        "The attempts distribution bins by per-student count")
                })
        }
    }
}
