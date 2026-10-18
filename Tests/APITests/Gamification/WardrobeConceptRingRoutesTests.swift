// Tests/APITests/Gamification/WardrobeConceptRingRoutesTests.swift
//
// The concept rings over the web surface (docs/student-wardrobe.md,
// "Concept rings"):
//
//   - POST /instructor/:id/concept sets, clears and refuses an unknown value
//   - full marks on a tagged assignment earn its ring on the account page
//   - an untagged assignment earns no concept ring
//   - a regrade does not take a ring away

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct WardrobeConceptRingRoutesTests {

    /// Gives the logged-in student one graded submission on a new assignment
    /// tagged with `concept`.
    private func gradeSubmission(
        id: String, setupID: String, concept: AssignmentConcept?, statuses: [TestStatus], on app: Application
    ) async throws {
        let student = try await wrStudentUser(on: app)
        try await wrEnrollUser(student, on: app)
        try await wrInsertSetup(id: setupID, on: app)
        let assignment = try await wrInsertAssignment(
            testSetupID: setupID, title: "Lab \(setupID)", isOpen: true, on: app)
        assignment.concept = concept
        try await assignment.save(on: app.db)
        try await wrInsertSubmission(
            id: id, testSetupID: setupID, userID: student.requireID(), attemptNumber: 2, on: app)
        try await wrInsertResult(
            submissionID: id,
            outcomes: statuses.enumerated().map { index, status in
                wrMakeOutcome(name: "test\(index).sh", tier: .pub, status: status)
            },
            on: app)
    }

    private func storedUnlocks(on app: Application) async throws -> Set<String> {
        let student = try await wrStudentUser(on: app)
        return Set(
            try await APIWardrobeUnlock.query(on: app.db).filter(\.$userID == student.requireID()).all().map(\.item))
    }

    @Test func settingEndpointSetsClearsAndRefuses() async throws {
        try await withWebRoutesApp { app in
            let instructorCookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            try await wrInsertSetup(id: "setup_cr1", on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_cr1", title: "Loops Lab", isOpen: false, on: app)

            let editPath = "/instructor/\(assignment.publicID)/edit"
            let (csrf, staffCookie) = try await csrfFields(for: editPath, cookie: instructorCookie, on: app)
            func post(_ concept: String) async throws -> String? {
                var location: String?
                try await app.asyncTest(
                    .POST, "/instructor/\(assignment.publicID)/concept",
                    beforeRequest: { req in
                        req.headers.add(name: .cookie, value: staffCookie)
                        try req.content.encode(["_csrf": csrf, "concept": concept], as: .urlEncodedForm)
                    },
                    afterResponse: { res in
                        #expect(res.status == .seeOther)
                        location = res.headers.first(name: .location)
                    })
                return location
            }

            #expect(try await post("loops")?.contains("notice=") == true)
            #expect(try await APIAssignment.find(assignment.requireID(), on: app.db)?.concept == .loops)

            // The edit page shows the stored concept and the ring it earns.
            let html = try await getHTML(editPath, cookie: staffCookie, on: app)
            #expect(html.contains("Wardrobe ring"))
            #expect(html.contains(#"<option value="loops" selected"#))
            #expect(html.contains("earn the Ouroboros ring."))

            // An unknown value is refused and changes nothing.
            #expect(try await post("recursion")?.contains("error=") == true)
            #expect(try await APIAssignment.find(assignment.requireID(), on: app.db)?.concept == .loops)

            // An empty value clears.
            #expect(try await post("")?.contains("notice=") == true)
            #expect(try await APIAssignment.find(assignment.requireID(), on: app.db)?.concept == nil)
        }
    }

    @Test func fullMarksOnATaggedAssignmentOpensItsRing() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let before = try await getHTML("/account", cookie: cookie, on: app)
            #expect(!before.contains("Ouroboros"))

            try await gradeSubmission(
                id: "cr_s1", setupID: "cr_a", concept: .loops, statuses: [.pass, .pass], on: app)
            let html = try await getHTML("/account", cookie: cookie, on: app)
            #expect(try await storedUnlocks(on: app).contains("border.ouroboros"))
            #expect(html.contains(#"name="border" value="ouroboros""#))
            // How it was earned is the result page's Earned toast to say
            // (EarnedToastRoutesTests), not the account page's.
            #expect(!html.contains("when every test passed on a loops lab"))
            #expect(!html.contains(#"name="border" value="pulse""#))
        }
    }

    @Test func anUntaggedAssignmentEarnsNoConceptRing() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await gradeSubmission(id: "cr_s2", setupID: "cr_b", concept: nil, statuses: [.pass], on: app)
            _ = try await getHTML("/account", cookie: cookie, on: app)
            let concepts = Set(AssignmentConcept.allCases.map { WardrobeItem(concept: $0).rawValue })
            #expect(try await storedUnlocks(on: app).isDisjoint(with: concepts))
        }
    }

    /// A ring is kept when the work that earned it is regraded away.
    @Test func aConceptRingIsKeptAfterARegrade() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await gradeSubmission(id: "cr_s3", setupID: "cr_c", concept: .binary, statuses: [.pass], on: app)
            _ = try await getHTML("/account", cookie: cookie, on: app)
            #expect(try await storedUnlocks(on: app).contains("border.binary"))

            try await APIResult.query(on: app.db).filter(\.$submissionID == "cr_s3").delete()
            let html = try await getHTML("/account", cookie: cookie, on: app)
            #expect(try await storedUnlocks(on: app).contains("border.binary"))
            #expect(html.contains(#"name="border" value="binary""#))
        }
    }
}
