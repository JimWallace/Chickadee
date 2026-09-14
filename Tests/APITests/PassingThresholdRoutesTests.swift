// Tests/APITests/PassingThresholdRoutesTests.swift
//
// The advisory passing threshold over the web surface:
//
//   - POST /instructor/:id/passing-threshold sets, clears, and refuses an
//     out-of-range value without writing it
//   - the instructor submissions page labels each graded student against the
//     threshold and counts them in a Passing card, and renders none of that
//     while the threshold is off

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized)
struct PassingThresholdRoutesTests {

    @Test func settingEndpointSetsClearsAndRefuses() async throws {
        try await withWebRoutesApp { app in
            let instructorCookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            try await wrInsertSetup(id: "setup_pt1", on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_pt1", title: "Threshold Lab", isOpen: false, on: app)

            let editPath = "/instructor/\(assignment.publicID)/edit"
            let (csrf, staffCookie) = try await csrfFields(
                for: editPath, cookie: instructorCookie, on: app)
            let postPath = "/instructor/\(assignment.publicID)/passing-threshold"

            try await app.asyncTest(
                .POST, postPath,
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: staffCookie)
                    try req.content.encode(
                        ["_csrf": csrf, "passingThresholdPercent": "60"], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("notice=") == true)
                })
            var reloaded = try await APIAssignment.find(assignment.requireID(), on: app.db)
            #expect(reloaded?.passingThresholdPercent == 60)

            // The edit page shows the stored value in the control.
            try await app.asyncTest(
                .GET, editPath,
                beforeRequest: { req in req.headers.add(name: .cookie, value: staffCookie) },
                afterResponse: { res in
                    #expect(res.body.string.contains(#"name="passingThresholdPercent""#))
                    #expect(res.body.string.contains(#"value="60""#))
                })

            // Out of range: refused with an error banner, value untouched.
            try await app.asyncTest(
                .POST, postPath,
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: staffCookie)
                    try req.content.encode(
                        ["_csrf": csrf, "passingThresholdPercent": "150"], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("error=") == true)
                })
            reloaded = try await APIAssignment.find(assignment.requireID(), on: app.db)
            #expect(reloaded?.passingThresholdPercent == 60, "a refused value must not overwrite")

            // Empty field clears.
            try await app.asyncTest(
                .POST, postPath,
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: staffCookie)
                    try req.content.encode(
                        ["_csrf": csrf, "passingThresholdPercent": ""], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })
            reloaded = try await APIAssignment.find(assignment.requireID(), on: app.db)
            #expect(reloaded?.passingThresholdPercent == nil)
        }
    }

    @Test func submissionsPageLabelsAndCountsAgainstTheThreshold() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)

            let alice = try await arInsertStudent(username: "pt_alice", on: app)
            try await arEnrollStudentInTestCourse(alice, on: app)
            let bob = try await arInsertStudent(username: "pt_bob", on: app)
            try await arEnrollStudentInTestCourse(bob, on: app)
            let carol = try await arInsertStudent(username: "pt_carol", on: app)
            try await arEnrollStudentInTestCourse(carol, on: app)

            try await arInsertSetup(id: "pt_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "pt_setup", title: "Threshold Lab", isOpen: true, on: app)

            // Alice 80%, Bob 40%, Carol no submission.
            _ = try await arInsertSubmission(
                id: "sub_pt_a", testSetupID: "pt_setup", userID: alice.requireID(),
                attemptNumber: 1, on: app)
            try await APIResult(id: "res_pt_a", submissionID: "sub_pt_a").saveWithCollection(
                json: #"{"passCount":4,"totalTests":5}"#, on: app.db)
            _ = try await arInsertSubmission(
                id: "sub_pt_b", testSetupID: "pt_setup", userID: bob.requireID(),
                attemptNumber: 1, on: app)
            try await APIResult(id: "res_pt_b", submissionID: "sub_pt_b").saveWithCollection(
                json: #"{"passCount":2,"totalTests":5}"#, on: app.db)

            let page = "/instructor/\(assignment.publicID)/submissions"

            // Threshold off: no badge, no card.
            try await app.asyncTest(
                .GET, page,
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(!res.body.string.contains("below threshold"))
                    #expect(!res.body.string.contains(">passing<"))
                    #expect(!res.body.string.contains("Passing ("))
                })

            assignment.passingThresholdPercent = 60
            try await assignment.save(on: app.db)

            try await app.asyncTest(
                .GET, page,
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains(#"<span class="tier tier-open">passing</span>"#))
                    #expect(body.contains(#"<span class="tier tier-closed">below threshold</span>"#))
                    #expect(body.contains("Passing (60%)"))
                    #expect(body.contains(">1/2<"), "one of the two graded students passes")
                    // The ungraded student carries no label at all.
                    #expect(body.components(separatedBy: "below threshold").count == 2)
                })
        }
    }
}
