// Tests/APITests/WebRoutesSecretRevealTests.swift
//
// Secret-reveal token flow, end to end over the web surface:
//
//   - the offer box renders only when (toggle on ∧ secret tests ∧ non-staff
//     owner ∧ unspent)
//   - POST /testsetups/:id/reveal-secret spends exactly once, and refuses
//     (without writing a row) when the toggle is off or the caller is staff
//   - after the spend, secret rows itemize with output while the aggregate
//     "hidden tests" summary disappears; toggle-off re-hides them
//   - the JSON results API includes secret outcomes post-spend, under a
//     fresh ETag
//   - staff re-grant deletes the spend row and restores the offer
//   - the instructor edit-page toggle endpoint sets and clears the flag

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite struct WebRoutesSecretRevealTests {

    /// Seeds course + secret-tier setup + assignment + one graded submission
    /// for student1, returning the logged-in student cookie.
    @discardableResult
    private func seedRevealFixture(
        app: Application,
        setupID: String,
        subID: String,
        secretRevealEnabled: Bool = true,
        manifest: String = wrManifestWithSecretTier
    ) async throws -> (cookie: String, student: APIUser, assignment: APIAssignment) {
        let cookie = try await wrLoginAsStudent(on: app)
        let student = try await wrStudentUser(on: app)
        try await wrEnrollUser(student, on: app)
        try await wrInsertSetup(id: setupID, manifest: manifest, on: app)
        let assignment = try await wrInsertAssignment(
            testSetupID: setupID, title: "Reveal Lab", isOpen: true,
            secretRevealEnabled: secretRevealEnabled, on: app)
        try await wrInsertSubmission(
            id: subID, testSetupID: setupID, userID: student.requireID(), on: app)
        try await wrInsertResult(
            submissionID: subID,
            outcomes: [
                wrMakeOutcome(name: "test.sh", tier: .pub, status: .pass),
                wrMakeOutcome(
                    name: "secrettest.sh", tier: .secret, status: .fail,
                    shortResult: "secret case failed",
                    longResult: "SecretTraceback: expected 42"),
            ],
            on: app)
        return (cookie, student, assignment)
    }

    private func spendPOST(
        app: Application, setupID: String, subID: String, cookie: String
    ) async throws -> HTTPStatus {
        let (csrf, sessionCookie) = try await csrfFields(
            for: "/submissions/\(subID)", cookie: cookie, on: app)
        var status = HTTPStatus.imATeapot
        try await app.asyncTest(
            .POST, "/testsetups/\(setupID)/reveal-secret",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                try req.content.encode(
                    ["_csrf": csrf, "submissionID": subID], as: .urlEncodedForm)
            },
            afterResponse: { res in
                status = res.status
            })
        return status
    }

    private func submissionPageHTML(
        app: Application, subID: String, cookie: String
    ) async throws -> String {
        var html = ""
        try await app.asyncTest(
            .GET, "/submissions/\(subID)",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                #expect(res.status == .ok)
                html = res.body.string
            })
        return html
    }

    // MARK: - Offer rendering

    @Test func offerRendersForEligibleStudent() async throws {
        try await withWebRoutesApp { app in
            let (cookie, _, _) = try await seedRevealFixture(
                app: app, setupID: "setup_sr1", subID: "sub_sr1")
            let html = try await submissionPageHTML(app: app, subID: "sub_sr1", cookie: cookie)
            #expect(html.contains("/testsetups/setup_sr1/reveal-secret"))
            #expect(html.contains("one reveal token"))
            // Secret stays aggregated pre-spend.
            #expect(html.contains("hidden test 1"), "masked itemization pre-spend")
            #expect(!html.contains("SecretTraceback"))
        }
    }

    @Test func offerHiddenWhenToggleOff() async throws {
        try await withWebRoutesApp { app in
            let (cookie, _, _) = try await seedRevealFixture(
                app: app, setupID: "setup_sr2", subID: "sub_sr2", secretRevealEnabled: false)
            let html = try await submissionPageHTML(app: app, subID: "sub_sr2", cookie: cookie)
            #expect(!html.contains("/testsetups/setup_sr2/reveal-secret"))
        }
    }

    @Test func offerHiddenWhenNoSecretTests() async throws {
        try await withWebRoutesApp { app in
            let (cookie, _, _) = try await seedRevealFixture(
                app: app, setupID: "setup_sr3", subID: "sub_sr3",
                manifest: """
                    {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
                    """)
            let html = try await submissionPageHTML(app: app, subID: "sub_sr3", cookie: cookie)
            #expect(!html.contains("reveal-secret"))
        }
    }

    @Test func offerHiddenForStaffViewer() async throws {
        try await withWebRoutesApp { app in
            let (_, _, _) = try await seedRevealFixture(
                app: app, setupID: "setup_sr4", subID: "sub_sr4")
            let instructorCookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            let html = try await submissionPageHTML(
                app: app, subID: "sub_sr4", cookie: instructorCookie)
            #expect(!html.contains("reveal-secret"))
            // Staff itemize secret regardless of any token.
            #expect(html.contains("SecretTraceback"))
        }
    }

    // MARK: - Spend POST

    @Test func spendRevealsSecretRowsAndDropsAggregate() async throws {
        try await withWebRoutesApp { app in
            let (cookie, student, assignment) = try await seedRevealFixture(
                app: app, setupID: "setup_sr5", subID: "sub_sr5")
            let status = try await spendPOST(
                app: app, setupID: "setup_sr5", subID: "sub_sr5", cookie: cookie)
            #expect(status == .seeOther)

            let spent = try await SecretRevealStore.hasSpentToken(
                userID: student.requireID(), assignmentID: assignment.requireID(), on: app.db)
            #expect(spent)

            let html = try await submissionPageHTML(app: app, subID: "sub_sr5", cookie: cookie)
            #expect(html.contains("Secret tests revealed"), "active banner shows post-spend")
            #expect(html.contains("secrettest.sh"), "secret row is itemized")
            #expect(html.contains("SecretTraceback"), "secret output shows like public output")
            #expect(!html.contains("hidden test 1"), "masking is gone once the token is spent")
            #expect(!html.contains("reveal-secret"), "offer no longer renders once spent")
        }
    }

    @Test func doubleSpendKeepsOneRow() async throws {
        try await withWebRoutesApp { app in
            let (cookie, student, assignment) = try await seedRevealFixture(
                app: app, setupID: "setup_sr6", subID: "sub_sr6")
            _ = try await spendPOST(app: app, setupID: "setup_sr6", subID: "sub_sr6", cookie: cookie)
            _ = try await spendPOST(app: app, setupID: "setup_sr6", subID: "sub_sr6", cookie: cookie)
            let rowCount = try await APISecretRevealUnlock.query(on: app.db)
                .filter(\.$userID == student.requireID())
                .filter(\.$assignmentID == assignment.requireID())
                .count()
            #expect(rowCount == 1)
        }
    }

    @Test func spendRefusedWhenToggleOff() async throws {
        try await withWebRoutesApp { app in
            let (cookie, student, assignment) = try await seedRevealFixture(
                app: app, setupID: "setup_sr7", subID: "sub_sr7", secretRevealEnabled: false)
            let status = try await spendPOST(
                app: app, setupID: "setup_sr7", subID: "sub_sr7", cookie: cookie)
            #expect(status == .seeOther, "refusal is a redirect, not an error page")
            let spent = try await SecretRevealStore.hasSpentToken(
                userID: student.requireID(), assignmentID: assignment.requireID(), on: app.db)
            #expect(spent == false, "a hand-crafted POST with the toggle off writes no row")
        }
    }

    @Test func spendRefusedForStaff() async throws {
        try await withWebRoutesApp { app in
            _ = try await seedRevealFixture(app: app, setupID: "setup_sr8", subID: "sub_sr8")
            let instructorCookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)

            let (csrf, sessionCookie) = try await csrfFields(
                for: "/submissions/sub_sr8", cookie: instructorCookie, on: app)
            try await app.asyncTest(
                .POST, "/testsetups/setup_sr8/reveal-secret",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })
            let spendCount = try await APISecretRevealUnlock.query(on: app.db).count()
            #expect(spendCount == 0, "staff spends are refused without a row")
        }
    }

    // MARK: - Toggle-off after spend

    @Test func toggleOffAfterSpendReAggregatesSecret() async throws {
        try await withWebRoutesApp { app in
            let (cookie, _, assignment) = try await seedRevealFixture(
                app: app, setupID: "setup_sr9", subID: "sub_sr9")
            _ = try await spendPOST(app: app, setupID: "setup_sr9", subID: "sub_sr9", cookie: cookie)

            assignment.secretRevealEnabled = false
            try await assignment.save(on: app.db)

            let html = try await submissionPageHTML(app: app, subID: "sub_sr9", cookie: cookie)
            #expect(html.contains("hidden test 1"), "masked itemization returns")
            #expect(!html.contains("SecretTraceback"), "secret output is hidden again")
            #expect(!html.contains("reveal-secret"), "no offer while the toggle is off")
        }
    }

    // MARK: - JSON results API

    @Test func resultsAPIIncludesSecretAfterSpendWithFreshETag() async throws {
        try await withWebRoutesApp { app in
            let (cookie, _, _) = try await seedRevealFixture(
                app: app, setupID: "setup_sr10", subID: "sub_sr10")

            var etagBefore = ""
            try await app.asyncTest(
                .GET, "/api/v1/submissions/sub_sr10/results",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    etagBefore = res.headers.first(name: .eTag) ?? ""
                    let collection = try res.content.decode(TestOutcomeCollection.self)
                    #expect(!collection.outcomes.contains { $0.tier == .secret })
                })

            _ = try await spendPOST(
                app: app, setupID: "setup_sr10", subID: "sub_sr10", cookie: cookie)

            try await app.asyncTest(
                .GET, "/api/v1/submissions/sub_sr10/results",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    // A cached pre-spend ETag must not produce a 304 now.
                    req.headers.add(name: .ifNoneMatch, value: etagBefore)
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "spend busts the pre-spend ETag")
                    let etagAfter = res.headers.first(name: .eTag) ?? ""
                    #expect(etagAfter != etagBefore)
                    let collection = try res.content.decode(TestOutcomeCollection.self)
                    #expect(collection.outcomes.contains { $0.tier == .secret })
                })
        }
    }

    // MARK: - Staff re-grant

    @Test func regrantDeletesSpendAndRestoresOffer() async throws {
        try await withWebRoutesApp { app in
            let (cookie, student, assignment) = try await seedRevealFixture(
                app: app, setupID: "setup_sr11", subID: "sub_sr11")
            _ = try await spendPOST(
                app: app, setupID: "setup_sr11", subID: "sub_sr11", cookie: cookie)

            let instructorCookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)

            // Roster shows the spent tag + re-grant action while spent.
            let rosterPath = "/instructor/\(assignment.publicID)/submissions"
            let (csrf, staffCookie) = try await csrfFields(
                for: rosterPath, cookie: instructorCookie, on: app)
            let studentUUID = try student.requireID().uuidString
            try await app.asyncTest(
                .GET, rosterPath,
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: staffCookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("regrant-reveal-token"))
                })

            try await app.asyncTest(
                .POST,
                "/instructor/\(assignment.publicID)/students/\(studentUUID)/regrant-reveal-token",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: staffCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let spent = try await SecretRevealStore.hasSpentToken(
                userID: student.requireID(), assignmentID: assignment.requireID(), on: app.db)
            #expect(spent == false)

            let html = try await submissionPageHTML(app: app, subID: "sub_sr11", cookie: cookie)
            #expect(html.contains("reveal-secret"), "offer returns after the re-grant")
            #expect(!html.contains("SecretTraceback"), "secret output is hidden again")
        }
    }

    // MARK: - Instructor toggle endpoint

    @Test func toggleEndpointSetsAndClearsFlag() async throws {
        try await withWebRoutesApp { app in
            let instructorCookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            try await wrInsertSetup(id: "setup_sr12", manifest: wrManifestWithSecretTier, on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_sr12", title: "Toggle Lab", isOpen: false, on: app)

            let editPath = "/instructor/\(assignment.publicID)/edit"
            let (csrf, staffCookie) = try await csrfFields(
                for: editPath, cookie: instructorCookie, on: app)

            // Checked checkbox → enabled.
            try await app.asyncTest(
                .POST, "/instructor/\(assignment.publicID)/secret-reveal",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: staffCookie)
                    try req.content.encode(["_csrf": csrf, "enabled": "on"], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })
            let enabled = try await APIAssignment.find(assignment.requireID(), on: app.db)
            #expect(enabled?.secretRevealEnabled == true)

            // Edit page reflects the state.
            try await app.asyncTest(
                .GET, editPath,
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: staffCookie)
                },
                afterResponse: { res in
                    #expect(res.body.string.contains("checked"))
                })

            // Absent checkbox (unchecked) → disabled.
            try await app.asyncTest(
                .POST, "/instructor/\(assignment.publicID)/secret-reveal",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: staffCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })
            let disabled = try await APIAssignment.find(assignment.requireID(), on: app.db)
            #expect(disabled?.secretRevealEnabled == false)
        }
    }
}
